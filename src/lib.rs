use actix_web::{App, HttpServer};
use serde::{Serialize, Deserialize};
use std::string::String;

#[allow(dead_code)]
pub const MIN_PORT: u16 = 8081;

#[allow(dead_code)]
pub const MAX_PORT: u16 = 9000;

pub const REGISTRY_URL: &str = "http://localhost:8080";

#[derive(Serialize, Deserialize)]
struct FilterInfo {
    url: String,
}

#[allow(dead_code)]
pub async fn register_filter(url: &str) {
    let filter_info = FilterInfo { url: url.to_string() };
    let register_url = format!("{}/register", REGISTRY_URL);

    match reqwest::Client::new()
        .post(&register_url)
        .header("Content-Type", "application/json")
        .body(serde_json::to_string(&filter_info).expect("Error serializing JSON"))
        .send()
        .await
        {
            Ok(_) => println!("Filter registered with the central registry."),
            Err(e) => eprintln!("Failed to register filter: {:?}", e),
        }
}

#[allow(dead_code)]
pub async fn try_start_server(port: u16) -> std::io::Result<()> {
    let addr = format!("127.0.0.1:{}", port);
    println!("Trying to bind to port {}", port);
    let _ = HttpServer::new(|| App::new())
        .bind(addr)?
        .run();
    Ok(())
}

#[allow(dead_code)]
pub async fn find_port() -> Option<u16> {
    let mut port = MIN_PORT;
    loop {
        match try_start_server(port).await {
            Ok(_) => {
                break;
            },
            Err(_) => {
                if port >= MAX_PORT {
                    eprintln!("Unable to bind to any port in the range.");
                    return None
                }
                port+=1;
            }
        }
    }
    Some(port)
}

