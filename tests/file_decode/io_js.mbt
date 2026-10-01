///|
extern "js" fn io_config(index : Int) -> Int = "(i) => globalThis.__moonav1_fixture.config(i)"

///|
extern "js" fn io_open(kind : Int) -> Int = "(i) => globalThis.__moonav1_fixture.open(i)"

///|
extern "js" fn io_read(kind : Int) -> Int = "(i) => globalThis.__moonav1_fixture.read(i)"

///|
extern "js" fn io_rewind(kind : Int) -> Int = "(i) => globalThis.__moonav1_fixture.rewind(i)"

///|
extern "js" fn io_close(kind : Int) -> Unit = "(i) => globalThis.__moonav1_fixture.close(i)"
