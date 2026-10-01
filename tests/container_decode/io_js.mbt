///|
extern "js" fn io_config(index : Int) -> Int = "(i) => globalThis.__moonav1_container.config(i)"

///|
extern "js" fn io_open(kind : Int) -> Int = "(i) => globalThis.__moonav1_container.open(i)"

///|
extern "js" fn io_read(kind : Int) -> Int = "(i) => globalThis.__moonav1_container.read(i)"

///|
extern "js" fn io_seek(kind : Int, offset : Int64) -> Int = "(i, o) => globalThis.__moonav1_container.seek(i, o)"

///|
extern "js" fn io_close(kind : Int) -> Unit = "(i) => globalThis.__moonav1_container.close(i)"
