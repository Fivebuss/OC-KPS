-- Partal port of openOS's i/o library because I desperately need an stdout
-- With some of my own features
-- fd 0 = stdin, fd 1 = stdout, fd 2 = stderr.

-- Finally added fs + real buffer library

local filesystem = require("filesystem")
local buffer = polaris.buffer

local io = {}

-- So multiple fd via dup

-- __index is a function so that any method the underlying stream/buffer
-- supports (read, write, readLine, seek, flush, setvbuf, size, lines,
-- getTimeout, setTimeout, writeln, ...) yes I know its alot and yes I use them
local descriptorMethods = {}

-- dups exist for real
local descriptorMt = {
    __index = function(desc, key)
        local own = descriptorMethods[key]
        if own then
            return own
        end
        local target = rawget(desc, "_handle")._stream
        if target == nil then
            return nil
        end
        local fn = target[key]
        if type(fn) == "function" then
            -- shim
            return function(_, ...)
                return fn(target, ...)
            end
        end
        return fn
    end,
}

local function makeHandle(stream)
    return { _stream = stream, _refCount = 1 }
end

local function newDescriptor(stream)
    local handle = makeHandle(stream)
    return setmetatable({
        _handle = handle,
    }, descriptorMt)
end

-- Dup is real now
function descriptorMethods:retain()
    local handle = self._handle
    handle._refCount = handle._refCount + 1
    return setmetatable({ _handle = handle }, descriptorMt)
end

-- Releases one reference once refcount
function descriptorMethods:release()
    local handle = self._handle
    handle._refCount = handle._refCount - 1
    if handle._refCount <= 0 and handle._stream and handle._stream.close then
        handle._stream:close()
    end
end

-- File handlers are different
function descriptorMethods:readLine(...)
    local stream = self._handle._stream
    if not stream.readLine then
        return nil, "readLine not supported"
    end
    return stream:readLine(...)
end

function descriptorMethods:writeln(...)
    local stream = self._handle._stream
    if stream.writeln then
        return stream:writeln(...)
    end
    stream:write(...)
    return stream:write("\n")
end

function descriptorMethods:seek(...)
    local stream = self._handle._stream
    if not stream.seek then
        return nil, "seek not supported"
    end
    return stream:seek(...)
end

function descriptorMethods:flush(...)
    local stream = self._handle._stream
    if stream.flush then
        return stream:flush(...)
    end
    return true -- streams without flush are unbuffered
end

-- close() on a descriptor is just release()
function descriptorMethods:close()
    self:release()
end

-- The actual useful things
function descriptorMethods:read(...)
    return self._handle._stream:read(...)
end

function descriptorMethods:write(...)
    return self._handle._stream:write(...)
end

io.newDescriptor = newDescriptor


-- Filesystem operations
local fsStreamMt = { __index = {} }

function fsStreamMt.__index:read(n)
    -- buffer raw
    return self._handle:read(n)
end

function fsStreamMt.__index:write(data)
    return self._handle:write(data)
end

function fsStreamMt.__index:seek(whence, offset)
    return self._handle:seek(whence, offset)
end

function fsStreamMt.__index:close()
    return self._handle:close()
end

-- if buffer uses stuff on raw
function fsStreamMt.__index:flush()
    if self._handle.flush then
        return self._handle:flush()
    end
    return true
end

function fsStreamMt.__index:tell()
    if self._handle.tell then
        return self._handle:tell()
    end
    if self._handle.seek then
        return self._handle:seek("cur", 0)
    end
    return nil, "tell not supported"
end

local function newFileStream(path, mode)
    local handle, reason = filesystem.open(path, mode)
    if not handle then
        return nil, reason
    end
    return setmetatable({ _handle = handle }, fsStreamMt)
end

io.newFileStream = newFileStream

-- Descriptor of buffered stream, no you cannot steal other fd's
function io.open(path, mode)
    mode = mode or "r"
    local rawStream, reason = newFileStream(path, mode)
    if not rawStream then
        return nil, reason
    end
    return newDescriptor(buffer.new(mode, rawStream))
end

-- Lets cheat
io.EOF = setmetatable({}, { __tostring = function() return "<EOF>" end })

-- A minimal in-memory stream. write() accumulates; contents() reads
-- I forgot completely to fix this lol
local streamMt = { __index = {} }

function streamMt.__index:write(...)
    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        self._buf[#self._buf + 1] = tostring(v)
    end
    return self
end

function streamMt.__index:writeln(...)
    self:write(...)
    self._buf[#self._buf + 1] = "\n"
    return self
end

function streamMt.__index:contents()
    return table.concat(self._buf)
end

-- Drops chunks off the front
local function streamCompact(self)
    while self._buf[self._head] ~= nil and self._headOffset >= #self._buf[self._head] do
        self._buf[self._head] = nil
        self._head = self._head + 1
        self._headOffset = 0
    end
    if self._head > 64 and next(self._buf) == nil then
        self._buf, self._head, self._headOffset = {}, 1, 0
    end
end

-- Pulls count of bytes
local function streamTake(self, count)
    local out = {}
    local remaining = count -- nil means "take everything unread"

    while self._buf[self._head] ~= nil and (remaining == nil or remaining > 0) do
        local chunk = self._buf[self._head]
        local available = #chunk - self._headOffset

        if remaining ~= nil and remaining < available then
            out[#out + 1] = chunk:sub(self._headOffset + 1, self._headOffset + remaining)
            self._headOffset = self._headOffset + remaining
            remaining = 0
        else
            out[#out + 1] = chunk:sub(self._headOffset + 1)
            self._head = self._head + 1
            self._headOffset = 0
            if remaining ~= nil then
                remaining = remaining - available
            end
        end
    end

    streamCompact(self)
    return table.concat(out)
end

-- I want this
function streamMt.__index:read(count)
    self._head = self._head or 1
    self._headOffset = self._headOffset or 0

    if self._buf[self._head] == nil then
        return nil -- eof, nothing left unread
    end

    local result = streamTake(self, count)
    if result == "" then
        return nil
    end
    return result
end

function streamMt.__index:readLine()
    self._head = self._head or 1
    self._headOffset = self._headOffset or 0

    if self._buf[self._head] == nil then
        return nil -- eof
    end

    -- Scan forward for \n
    local scanned = 0
    local idx = self._head
    local offset = self._headOffset

    while self._buf[idx] ~= nil do
        local chunk = self._buf[idx]
        local searchFrom = (idx == self._head) and (offset + 1) or 1
        local nl = chunk:find("\n", searchFrom, true)

        if nl then
            local lineLen = scanned + (nl - searchFrom)
            local line = streamTake(self, lineLen)
            streamTake(self, 1) -- almost forgot the nl
            return line
        end

        scanned = scanned + (#chunk - searchFrom + 1)
        idx = idx + 1
    end

    -- No newline found so
    return streamTake(self, nil)
end

function streamMt.__index:close()
    -- In-memory doesnt need this
end

local function newStream()
    return setmetatable({ _buf = {}, _head = 1, _headOffset = 0 }, streamMt)
end

io.newStream = newStream

-- Blocking pipes using scheduler

local pipeMt = { __index = {} }

-- scheduler: the scheduler module (needed to yield/resume the caller)
-- capacity: soft max buffered bytes before write() blocks the writer (optional, nil = unbounded)
-- Large things cause next write to be pressured!
local function newPipe(scheduler, capacity)
    return setmetatable({
        _buf = {},            -- queue of unread strings
        _head = 1,            -- index into _buf first not used
        _headOffset = 0,      -- how many bytes of _buf[_head] have already been used
        _size = 0,            -- unread bytes left
        _closedWrite = false, -- writer endpoint closed so reader gets EOF
        _closedRead = false,  -- reader endpoint closed
        _scheduler = scheduler,
        _capacity = capacity,
        _readerUid = nil, -- uid blocked in read(), if any
        _writerUid = nil, -- uid blocked in write() on backpressure, if any
    }, pipeMt)
end

io.newPipe = newPipe

-- O(1) in theory
local function pipeBufLen(self)
    return self._size
end

local function pipeWake(self, uidField)
    local uid = self[uidField]
    if uid then
        self[uidField] = nil
        self._scheduler.sendData(uid, true)
    end
end

-- So nothing is rebuilt
local function pipeCompact(self)
    while self._buf[self._head] ~= nil and self._headOffset >= #self._buf[self._head] do
        self._buf[self._head] = nil
        self._head = self._head + 1
        self._headOffset = 0
    end
    if self._head > 64 and next(self._buf) == nil then
        -- this is important
        self._buf, self._head, self._headOffset = {}, 1, 0
    end
end

-- write() blocks (yields) only if capacity is set and exceeded.
-- Returns false if the reader has closed their end (broken pipe?)
function pipeMt.__index:write(...)
    if self._closedRead then
        --print("[DEBUG] pipe write closed reader")
        return false -- nobody's listening
    end

    local n = select("#", ...)
    for i = 1, n do
        local v = select(i, ...)
        v = tostring(v)
        if #v > 0 then
            self._buf[#self._buf + 1] = v
            self._size = self._size + #v
        end
    end

    pipeWake(self, "_readerUid")

    while self._capacity
        and self._size > self._capacity
        and not self._closedRead
        and not self._closedWrite do
        self._writerUid = self._scheduler.currentThread()
        self._scheduler.waitForInput()
        self._scheduler.checkCancel()
    end

    if self._closedRead then
        return false
    end

    return true
end

function pipeMt.__index:writeln(...)
    return self:write(..., "\n")
end

-- Counts queue
local function pipeTake(self, count)
    local out = {}
    local remaining = count -- nil means "take everything"

    while self._buf[self._head] ~= nil and (remaining == nil or remaining > 0) do
        local chunk = self._buf[self._head]
        local available = #chunk - self._headOffset

        if remaining ~= nil and remaining < available then
            out[#out + 1] = chunk:sub(self._headOffset + 1, self._headOffset + remaining)
            self._headOffset = self._headOffset + remaining
            self._size = self._size - remaining
            remaining = 0
        else
            out[#out + 1] = chunk:sub(self._headOffset + 1)
            self._size = self._size - available
            self._head = self._head + 1
            self._headOffset = 0
            if remaining ~= nil then
                remaining = remaining - available
            end
        end
    end

    pipeCompact(self)
    return table.concat(out)
end

-- read(count): blocks until >=1 byte available or EOF.
-- count == nil reads whatever is currently queued and blocks if else
function pipeMt.__index:read(count)
    while true do
        if self._size > 0 then
            local result = pipeTake(self, count)
            pipeWake(self, "_writerUid")
            return result
        end

        if self._closedWrite then
            return nil -- EOF
        end

        self._readerUid = self._scheduler.currentThread()
        self._scheduler.waitForInput()
        self._scheduler.checkCancel() -- ^C while blocked mid-pipe
    end
end

function pipeMt.__index:readLine()
    while true do
        -- Looks for \n without viewing entire thing
        local scanned = 0
        local idx = self._head
        local offset = self._headOffset
        while self._buf[idx] ~= nil do
            local chunk = self._buf[idx]
            local searchFrom = (idx == self._head) and (offset + 1) or 1
            local nl = chunk:find("\n", searchFrom, true)
            if nl then
                local lineLen = scanned + (nl - searchFrom)
                local line = pipeTake(self, lineLen)
                pipeTake(self, 1) -- consume the newline itself
                pipeWake(self, "_writerUid")
                return line
            end
            scanned = scanned + (#chunk - searchFrom + 1)
            idx = idx + 1
        end

        if self._closedWrite then
            if self._size > 0 then
                local rest = pipeTake(self, nil)
                pipeWake(self, "_writerUid")
                return rest
            end
            return nil
        end

        self._readerUid = self._scheduler.currentThread()
        self._scheduler.waitForInput()
        self._scheduler.checkCancel()
    end
end

-- Writer side is done producing (e.g. cat reached EOF on the file)
function pipeMt.__index:close()
    self._closedWrite = true
    pipeWake(self, "_readerUid")
end

-- Reader side is done consuming (e.g. head got its N bytes and quit).
-- Lets an infinite producer like `cat /dev/random` stop instead of writing
-- forever into a pipe nobody will ever read from again
function pipeMt.__index:closeRead()
    --print("[DEBUG] pipe closeRead")
    self._closedRead = true
    pipeWake(self, "_writerUid")
end

-- So endpoint:close is usable all over
-- Mmmmmm metatables

local pipeReaderMt = { __index = {} }
local pipeWriterMt = { __index = {} }

function pipeReaderMt.__index:read(...) return self._pipe:read(...) end

function pipeReaderMt.__index:readLine(...) return self._pipe:readLine(...) end

function pipeReaderMt.__index:close() return self._pipe:closeRead() end

function pipeWriterMt.__index:write(...) return self._pipe:write(...) end

function pipeWriterMt.__index:writeln(...) return self._pipe:writeln(...) end

function pipeWriterMt.__index:close() return self._pipe:close() end

-- Reader and writer are different
local function newPipeEndpoints(scheduler, capacity)
    local pipe = newPipe(scheduler, capacity)
    local reader = setmetatable({ _pipe = pipe }, pipeReaderMt)
    local writer = setmetatable({ _pipe = pipe }, pipeWriterMt)
    return reader, writer
end

io.newPipeEndpoints = newPipeEndpoints

-- Line buffered

local lineBufferedMt = { __index = {} }

local function newLineBuffered(target)
    return setmetatable({ _target = target, _pending = {} }, lineBufferedMt)
end

local function lineBufferedFlushPending(self)
    if #self._pending > 0 then
        local chunk = table.concat(self._pending)
        self._pending = {}

        local result, reason = self._target:write(chunk)
        if not result then
            return nil, reason
        end

        -- A line-buffered flush must actually flush the target.
        if self._target.flush then
            return self._target:flush()
        end

        return result
    end

    return true
end

function lineBufferedMt.__index:write(...)
    local n = select("#", ...)
    local sawNewline = false
    for i = 1, n do
        local v = tostring((select(i, ...)))
        self._pending[#self._pending + 1] = v
        if v:find("\n", 1, true) then
            sawNewline = true
        end
    end
    if sawNewline then
        return lineBufferedFlushPending(self)
    end
    return true
end

function lineBufferedMt.__index:writeln(...)
    self:write(...)
    return self:write("\n")
end

function lineBufferedMt.__index:flush()
    return lineBufferedFlushPending(self)
end

function lineBufferedMt.__index:close()
    lineBufferedFlushPending(self)
    if self._target.close then
        return self._target:close()
    end
end

io.newLineBuffered = newLineBuffered

-- Each thread gets this

local threadIO = {} -- [threadUid] = { [0]=stdin, [1]=stdout, [2]=stderr }

-- Pipeline stuff
-- stdin/stdout/stderr are raw streams
-- stdin is fully buffered, stdout and err are line-buffered!
function io.initThread(uid, stdin, stdout, stderr)
    threadIO[uid] = {
        [0] = newDescriptor(buffer.new("r", stdin)),
        [1] = newDescriptor(newLineBuffered(buffer.new("w", stdout))),
        [2] = newDescriptor(newLineBuffered(buffer.new("w", stderr))),
    }
end

function io.cleanupThread(uid)
    io.closeAll(uid)
    threadIO[uid] = nil
end

local function currentIO(scheduler)
    local uid = scheduler.currentThread()
    if not uid then
        error("io must be used from within a running corountine: ", 2)
    end
    local t = threadIO[uid]
    if not t then
        error("io: no stream table for current thread", 2)
    end
    return t
end

-- Omg streams
function io.stream(scheduler, fd, file)
    io.checkArg1(fd)
    assert(fd == 0 or fd == 1 or fd == 2, "fd must be 0 (stdin), 1 (stdout), or 2 (stderr)")
    local t = currentIO(scheduler)
    if file then
        local newDesc = getmetatable(file) == descriptorMt and file or newDescriptor(file)
        local old = t[fd]
        t[fd] = newDesc
        if old then
            old:release()
        end
    end
    return t[fd]
end

function io.checkArg1(fd)
    if type(fd) ~= "number" then
        error("bad argument #1 (number expected, got " .. type(fd) .. ")", 3)
    end
end

function io.input(scheduler, file)
    return io.stream(scheduler, 0, file)
end

function io.output(scheduler, file)
    return io.stream(scheduler, 1, file)
end

function io.error(scheduler, file)
    return io.stream(scheduler, 2, file)
end

function io.write(scheduler, ...)
    return io.output(scheduler):write(...)
end

function io.writeError(scheduler, ...)
    local err = io.error(scheduler)
    return err:write(...)
end

-- Fixed
function io.closeAll(uid)
    local t = threadIO[uid]
    if not t then return end
    for fd = 0, 2 do
        local desc = t[fd]
        if desc then
            desc:release()
            t[fd] = nil
        end
    end
end

-- fd dupe
local dupMt = descriptorMt

function io.dup(descriptor)
    assert(getmetatable(descriptor) == descriptorMt, "io.dup expects a descriptor (see io.stream/io.initThread)")
    return descriptor:retain()
end

-- Inspect stuff

-- Unwraps stuff but also buffer isnt useful for this so we gotta check manually
local function isRealBufferObject(s)
    return type(s) == "table" and s.stream ~= nil and s.bufferRead ~= nil
end

local function unwrapStream(s)
    while s ~= nil do
        local mt = getmetatable(s)
        if mt == descriptorMt then
            s = s._handle._stream
        elseif mt == lineBufferedMt then
            s = s._target
        elseif mt == pipeReaderMt or mt == pipeWriterMt then
            s = s._pipe
        elseif isRealBufferObject(s) then
            s = s.stream
        else
            break
        end
    end
    return s
end

-- Get info passively
local function describeStream(desc)
    if not desc then
        return { present = false }
    end

    local isDescriptor = getmetatable(desc) == descriptorMt
    local s = unwrapStream(desc)
    local mt = s and getmetatable(s)

    local kind = "unknown"
    if mt == pipeMt then
        kind = "pipe"
    elseif mt == streamMt then
        kind = "stream"
    elseif mt == fsStreamMt then
        kind = "file"
    elseif s and type(s.write) == "function" then
        kind = "custom" -- outWriter(), ttys, etc
    end

    local info = { present = true, kind = kind }
    if isDescriptor then
        info.refCount = desc._handle._refCount
    end

    -- Custom ones do not have this
    if kind == "pipe" or kind == "stream" then
        info.bufferedBytes = (kind == "pipe") and s._size or (function()
            local n = 0
            for _, chunk in ipairs(s._buf or {}) do n = n + #chunk end
            return n
        end)()
    end
    if kind == "pipe" then
        info.closedWrite = s._closedWrite or false
        info.closedRead = s._closedRead or false
    end

    return info
end

-- Copy of fd tables
function io.listThreads()
    local out = {}
    for uid, fds in pairs(threadIO) do
        out[uid] = {
            [0] = describeStream(fds[0]),
            [1] = describeStream(fds[1]),
            [2] = describeStream(fds[2]),
        }
    end
    return out
end

-- Single thread data
function io.describeThread(uid)
    local fds = threadIO[uid]
    if not fds then return nil end
    return {
        [0] = describeStream(fds[0]),
        [1] = describeStream(fds[1]),
        [2] = describeStream(fds[2]),
    }
end

return io
