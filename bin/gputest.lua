ctty.attributes.line = false
io.write("\27[?25l")
io.flush()
io.writeln(tostring(ctty.cursor.visible))