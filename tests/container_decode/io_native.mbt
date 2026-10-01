/// File input only. No codec is called by the C adapter.

///|
extern "C" fn io_config(index : Int) -> Int = "moonav1_container_config"

///|
extern "C" fn io_open(kind : Int) -> Int = "moonav1_container_open"

///|
extern "C" fn io_read(kind : Int) -> Int = "moonav1_container_read"

///|
extern "C" fn io_seek(kind : Int, offset : Int64) -> Int = "moonav1_container_seek"

///|
extern "C" fn io_close(kind : Int) -> Unit = "moonav1_container_close"
