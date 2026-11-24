//! rustls client config trusting the macOS system roots (what `URLSession` trusts).

use std::sync::Arc;

use rustls::{ClientConfig, RootCertStore};

/// Blocking (reads the system keychain); call from `spawn_blocking`.
pub(crate) fn build_client_config() -> Result<Arc<ClientConfig>, String> {
    let mut roots = RootCertStore::empty();
    let loaded = rustls_native_certs::load_native_certs();
    let (added, ignored) = roots.add_parsable_certificates(loaded.certs);
    tracing::debug!(
        added,
        ignored,
        errors = loaded.errors.len(),
        "ws: native roots"
    );
    if added == 0 {
        return Err("no usable system root certificates".into());
    }
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let config = ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|e| e.to_string())?
        .with_root_certificates(roots)
        .with_no_client_auth();
    Ok(Arc::new(config))
}
