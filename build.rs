fn main() {
    if cfg!(target_os = "windows") {
        let mut resource = winresource::WindowsResource::new();
        resource.set_icon("harness-logo.ico");
        resource.compile().expect("failed to compile Windows resources");
    }
}
