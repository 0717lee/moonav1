/// File input only. No codec is called by the C adapter.

///|
extern "C" fn io_config(index : Int) -> Int = "moonav1_fixture_config"

///|
extern "C" fn io_open(kind : Int) -> Int = "moonav1_fixture_open"

///|
extern "C" fn io_read(kind : Int) -> Int = "moonav1_fixture_read"

///|
extern "C" fn io_rewind(kind : Int) -> Int = "moonav1_fixture_rewind"

///|
extern "C" fn io_close(kind : Int) -> Unit = "moonav1_fixture_close"
