fn main() {
    uniffi::generate_scaffolding("uniffi/zmanager_mobile_core.udl")
        .expect("failed to generate UniFFI scaffolding");
}
