//! Identity of the protocol implemented by this build, independent of installed runtime assets.

macro_rules! client_identity {
    ($version:literal, $kind:literal) => {
        pub const CLIENT_VERSION: &str = $version;
        pub const CLIENT_TYPE: &str = $kind;
        pub const USER_AGENT: &str = concat!("ZaloPC-darwin-", $kind, "v", $version);
    };
}

client_identity!("695", "23");
pub const WEB_CLIENT_TYPE: &str = "30";
pub const WS_ORIGIN: &str = "file://";
