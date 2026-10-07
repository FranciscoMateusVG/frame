fn main() {
    // Proc-macro include_str tracks existing SQL; Cargo must also notice newly
    // added migration files before re-expanding sqlx::migrate!.
    println!("cargo:rerun-if-changed=../../migrations");
}
