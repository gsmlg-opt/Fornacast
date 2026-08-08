use std::path::Path;
use std::time::Duration;

#[rustler::nif(schedule = "DirtyIo")]
fn test_dirty_io_wait(entered_path: String, release_path: String) -> Result<(), String> {
    std::fs::write(entered_path, b"entered").map_err(|error| error.to_string())?;

    while !Path::new(&release_path).exists() {
        std::thread::sleep(Duration::from_millis(2));
    }

    Ok(())
}

rustler::init!("Elixir.GitTransport.TestDirtyIoNative");
