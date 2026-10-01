///|
fn io_config(index : Int) -> Int = "moonav1_container_io" "config"

///|
fn io_open(kind : Int) -> Int = "moonav1_container_io" "open"

///|
fn io_read(kind : Int) -> Int = "moonav1_container_io" "read"

///|
fn io_seek(kind : Int, offset : Int64) -> Int = "moonav1_container_io" "seek"

///|
fn io_close(kind : Int) -> Unit = "moonav1_container_io" "close"
