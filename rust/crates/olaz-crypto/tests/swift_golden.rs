//! Golden vectors produced by running the Swift `ZaloCrypto`/`JSONLossless` (swiftc, macOS).
#![allow(clippy::unwrap_used, clippy::expect_used)]
use olaz_crypto::*;
use serde_json::Value;
use std::collections::BTreeMap;

fn texts() -> Vec<String> {
    vec![
        String::new(),
        "a".into(),
        r#"{"ok":true,"id":123}"#.into(),
        "Xin chào Việt Nam – tiếng Việt có dấu: ắằẳẵặ".into(),
        "emoji 😀👍🏽🇻🇳 end".into(),
        "exactly16bytes!!".into(),
        "Lorem ipsum đô la ".repeat(40),
        r#"{"msgId":7412345678901234567}"#.into(),
    ]
}

fn k16() -> Vec<u8> {
    b"0123456789abcdef".to_vec()
}

fn k32() -> Vec<u8> {
    (0..32u32).map(|i| ((i * 7 + 3) & 0xFF) as u8).collect()
}

fn iv() -> Vec<u8> {
    (0..16u8).map(|i| i + 1).collect()
}

fn hx(v: &[u8]) -> String {
    hex::encode(v)
}

fn b64(v: &[u8]) -> String {
    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, v)
}

fn map(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
        .collect()
}

#[test]
fn swift_golden_digests() {
    let md5 = [
        "d41d8cd98f00b204e9800998ecf8427e",
        "0cc175b9c0f1b6a831c399e269772661",
        "9d2641a97419d7e57c30e2e7ee91c28b",
        "47e19a4fd38fcb081175b99a9c1702d1",
        "59e960e76a2b66653213ed76eea55bba",
        "793412affc481080991b8525f2c00634",
        "d54381d15268f3ee4e548f1c933ea557",
        "392a0f6e8e5f874f873a503a6ea8b6c2",
    ];
    let sha = [
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
        "2bc34c605b60a4c7a44e93b7f7e984303c49a716feef0cf6e4656a1fe1055957",
        "ab8fc397fb702da4d40bba53c88bcefd90a89ff97ddb2c91815ecff29cdee63c",
        "6bd36dd02ade9577ff355c04b21e28d24c820e32abe117dc3a65875290d18ffb",
        "d0467cc44f6bbdfa877046ef4839e522a1ef6cab92c13f40330e5ad3178277f3",
        "04a970864a4636e4528c913c6f38b16701ffecb888782ca96953698e2230ab04",
        "58d9b236b6cac42dfb2b141bf48e3a3a277386789aaf08850b3ab7988406ec0e",
    ];
    let sha_upper = [
        "E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855",
        "CA978112CA1BBDCAFAC231B39A23DC4DA786EFF8147C4E72B9807785AFEE48BB",
        "2BC34C605B60A4C7A44E93B7F7E984303C49A716FEEF0CF6E4656A1FE1055957",
        "AB8FC397FB702DA4D40BBA53C88BCEFD90A89FF97DDB2C91815ECFF29CDEE63C",
        "6BD36DD02ADE9577FF355C04B21E28D24C820E32ABE117DC3A65875290D18FFB",
        "D0467CC44F6BBDFA877046EF4839E522A1EF6CAB92C13F40330E5AD3178277F3",
        "04A970864A4636E4528C913C6F38B16701FFECB888782CA96953698E2230AB04",
        "58D9B236B6CAC42DFB2B141BF48E3A3A277386789AAF08850B3AB7988406EC0E",
    ];
    for (i, t) in texts().iter().enumerate() {
        assert_eq!(md5_hex(t), md5[i]);
        assert_eq!(md5_hex(t.as_bytes()), md5[i]);
        assert_eq!(sha256_hex(t), sha[i]);
        assert_eq!(sha256_hex_upper(t), sha_upper[i]);
    }
}

#[test]
fn swift_golden_aes_cbc_zero_iv() {
    let e16 = [
        "N3Ii4GGpJMWRzZwn6hY+1A==",
        "CVABPXftKQXOUGN+ylRC7g==",
        "4QCmZ5GFOvG+EUZ7pn4hBSdxHcw6HYoBXchm4odM7UI=",
        "dobzxM6ZiqR89KeAcs1vXcGJEu7nnkLSbSs6aEXmO+w12FUtMbKOA4CG99EBCuUFMRCb9pZoEC8r456WL3K7BWeeMgQmOIhp7MVABx186dQ=",
        "9LM/OhawVYUfEhLWqyXs6g09sb5G6grBczpnfXsDexY=",
        "vySh1i6plfqwFBKXZlyeIgCcet0x+oOiXXQ/t9wzxV4=",
        "uVVWIfFGqdPeyOP4uv0bG4LNNvlChA0Kbhp50nFwGOgBVfrV9+4UzW7MXl0CfGoRDdVpDQtuFKC1ff0FzVhG38d7x+z/32yp9qMS7rKe31sFivqJ2lRa/E53azHKpduImj1QVLJKc3hMQENbLrdEKB9XfhhuoWLKGnW/6ot919FgylVGmUDsb9j0eEk5tPo29ekJJ2Q3F/bVTWyno8asF3fnZvv9xhxPJutmaqygo72rcEymc3H4fTHLV6aMiQywbTBVnDQK9S7kcxd87Z2JhdX+3SdjIqvJHxMg1hkzKrHkiTd3g47GExssvZjrYJJFvkml0bhNANmAeySdcVKTOAjznghMmw3on1j5difaWhoz2+JrELqR22CcEZGcXih4xoUGqWi1sWrG8ls6bf/tA+PYfXSVQTV0IdIatH8+ZuY/wU3o35m2H5fWL67wfjjP1XCuN0M9ALfasyH4TNcArrL660C8csLG9fUc6sfGl07EbuW+y49O2sPcxtc8q7FsyHKmPZOZouj6IRX+zn2NdxJd3dBWv7Yfbh1/YWA/5ZEefJOkrq3/MDjFidFaXO8eteojeKQHVMZE8nvGCDaVainp+FTf90kV5bQ0OB3P76L4OChO263eX7g6OOhaqwoKkFtxQnJ3IUXGlDk4GNqzSIYnoc17vu2IbnDVA2WbAHlCWd0lKpdQKd2JpkWSDZIRBten9mL2z4VyXQ8Ad06VFHuWfQ91qyK9lKRMEJy8VPXzDd1iOsOV1/zWrTVaTNAKx8BOpzAjJB5siTDit3kwvH1LE2hvvWmfWk2YOhlybVU4ZRifdTqVxIzNKZRIytagiSgBYY55eLYNaOD+jA4BuWuQFU8IuIMD6BWhAWtOVGs2E7gkFhzRazA2KQ28Ms8+tRui6K27kmBhkt7IUMuTdqcOeCloDfcvxyjtfq1vRWbU0Uf/pZuN2AwfU0lSZzxQI/G4jnPmRVk4Hzoqf9ODs96UOD8kDnPh1pD3S0DG1aZ/lARbnFPAzum0u36MSQ8qNn9IPad+aXG8HBsdVlnLo36aUz7mdlBU/gZ9jaXz7YlMzPUiEDXPtUQ03DrWiK4W",
        "vrwNl87ALkryxps5+Nx1bY+LWcgMhqB3gdR1T9NH8dM=",
    ];
    let e32 = [
        "FkbVk/jhmLwreJxRHNRg3A==",
        "s8N8lO0Ki3VIeuCWjyPsFw==",
        "/V7BEf1CQWeSngfyHVrT3LjmAoHtzvec2EWTTst5Q/Y=",
        "dEBoKfiw/6WTi3g5RabDnqegwTVUoy5k5uYUNNLsVBiIqyixjXfeIOTMSvSbQLkTGIQijAHbea+a3nLARSFIggWmyD5K8J4/BghZJtXdmgU=",
        "z79aNg095fJ7JMkDJLyDZL9vgaKQ46CW6Sbz+WSPvGA=",
        "tA+lkdJ+lHvZJBQm/BhJBU5v8A8w4h8NGcF1mXBn154=",
        "yHN7INbg3P4yBLPJ9jEnlqoXhNW+dWUJYNCEAjgUcLRbbyrfzuVH0bCZaPZyb1ocRlnHDCRK/Hu4stBQM6JKy8HkSJKjoaOKIhQU/vg1ByON09KthL/OaFpOK58K1dgVDrcePsiL66JDCGpiDF1g5ylHaFTXIll4wktHUXFjvSlEEwTQcL8HTHnE/nvVXE/Bigr944ib2dp+53eR3kyu2TGk37FYM8cEoPJvYaxw1gyyxnSsy+vHe/IQyII1/dCBhZQXg1DcdQp/MYZ873az9jEvma0odeoY2qJeWkPOz7P67bL/cYylOZmqNIJoLYVsiDL+m3Q8iKx9prVnAFgWqAnSCN+yjAa6girYyl/wv4D1qaoY/38npr1rZ8CjC6o72ut6mwPqWuHQJPC94HbuRjFl6yYtRV01IkUz6eTCWToBV65ITxAUxf9dwlYukzipGA9WUXKirS18iUR1nyrNW2MgLBV8jGTCYfXR5tSBf2H3qn/jZmj2cTltq6cQTJ93MVJvjajx39hPPz7b1ULSlYdUfXuKW2z0ifmQ0PUQwvAk4ZaPiw7F3J3OkrJ4aljSkRf6FcAaBC42yCQYh2w3H8H0uqFPoAa73ZIBhFEokDvAZt9AccRfXpuR61djjKd7HcgGqaD7nNrF5k/lB2iEXRe5dCD2ORXZ2C4IEnC/ewhhN4cc5qsboDwKNXqConne12k94Lk2DW46uq0+V8CvkMZ+v60Rnzd69kT4YqQNTOntW3Nq7ixvCIfiKiDDl2QDx+ZW4nv5xPcUR7ZQFLYNhGYBn/nvlzFBSgnAXYNIMB8pNzcCA5w3V+IOodXI4toNC+Ele9h5X+IFKqKAn7vHbTRcgfdIxkGW7Gnucmd6frhKdeGHXDsAFr48xC+Wuvcv6UEYM9QHVxVWIuttZZAU+YSegwbicUgRF8lMK/dBmuCKxHIl9A3CKR2K6qhsk6KBLCxmgNRlzb2Ne1w6j3O52i90nx/b40ofd0YKtul/opRyu7FgHEvedG0a4OTipykCeYI2b/HrVp8BdGeP0T/NILCGui/AscQBUiR2M/fOHEhZy+0E+PieRdUHCNdmRtxG",
        "ojUNynwi9Bk94jeMSg7NN2Dfs0jYzoNwZXg99REYg8c=",
    ];
    let ehex = [
        "377222E061A924C591CD9C27EA163ED4",
        "0950013D77ED2905CE50637ECA5442EE",
        "E100A66791853AF1BE11467BA67E210527711DCC3A1D8A015DC866E2874CED42",
        "7686F3C4CE998AA47CF4A78072CD6F5DC18912EEE79E42D26D2B3A6845E63BEC35D8552D31B28E038086F7D1010AE50531109BF69668102F2BE39E962F72BB05679E320426388869ECC540071D7CE9D4",
        "F4B33F3A16B055851F1212D6AB25ECEA0D3DB1BE46EA0AC1733A677D7B037B16",
        "BF24A1D62EA995FAB0141297665C9E22009C7ADD31FA83A25D743FB7DC33C55E",
        "B9555621F146A9D3DEC8E3F8BAFD1B1B82CD36F942840D0A6E1A79D2717018E80155FAD5F7EE14CD6ECC5E5D027C6A110DD5690D0B6E14A0B57DFD05CD5846DFC77BC7ECFFDF6CA9F6A312EEB29EDF5B058AFA89DA545AFC4E776B31CAA5DB889A3D5054B24A73784C40435B2EB744281F577E186EA162CA1A75BFEA8B7DD7D160CA55469940EC6FD8F4784939B4FA36F5E90927643717F6D54D6CA7A3C6AC1777E766FBFDC61C4F26EB666AACA0A3BDAB704CA67371F87D31CB57A68C890CB06D30559C340AF52EE473177CED9D8985D5FEDD276322ABC91F1320D619332AB1E4893777838EC6131B2CBD98EB609245BE49A5D1B84D00D9807B249D7152933808F39E084C9B0DE89F58F97627DA5A1A33DBE26B10BA91DB609C11919C5E2878C68506A968B5B16AC6F25B3A6DFFED03E3D87D749541357421D21AB47F3E66E63FC14DE8DF99B61F97D62FAEF07E38CFD570AE37433D00B7DAB321F84CD700AEB2FAEB40BC72C2C6F5F51CEAC7C6974EC46EE5BECB8F4EDAC3DCC6D73CABB16CC872A63D9399A2E8FA2115FECE7D8D77125DDDD056BFB61F6E1D7F61603FE5911E7C93A4AEADFF3038C589D15A5CEF1EB5EA2378A40754C644F27BC60836956A29E9F854DFF74915E5B434381DCFEFA2F838284EDBADDE5FB83A38E85AAB0A0A905B714272772145C694393818DAB3488627A1CD7BBEED886E70D503659B00794259DD252A975029DD89A645920D921106D7A7F662F6CF85725D0F00774E95147B967D0F75AB22BD94A44C109CBC54F5F30DDD623AC395D7FCD6AD355A4CD00AC7C04EA73023241E6C8930E2B77930BC7D4B13686FBD699F5A4D983A19726D553865189F753A95C48CCD299448CAD6A0892801618E7978B60D68E0FE8C0E01B96B90154F08B88303E815A1016B4E546B3613B824161CD16B3036290DBC32CF3EB51BA2E8ADBB92606192DEC850CB9376A70E7829680DF72FC728ED7EAD6F4566D4D147FFA59B8DD80C1F534952673C5023F1B88E73E64559381F3A2A7FD383B3DE94383F240E73E1D690F74B40C6D5A67F94045B9C53C0CEE9B4BB7E8C490F2A367F483DA77E6971BC1C1B1D5659CBA37E9A533EE6765054FE067D8DA5F3ED894CCCF5221035CFB54434DC3AD688AE16",
        "BEBC0D97CEC02E4AF2C69B39F8DC756D8F8B59C80C86A07781D4754FD347F1D3",
    ];
    for (i, t) in texts().iter().enumerate() {
        assert_eq!(encode_aes(&k16(), t).unwrap(), e16[i]);
        assert_eq!(decode_aes(&k16(), e16[i]).unwrap(), *t);
        assert_eq!(encode_aes(&k32(), t).unwrap(), e32[i]);
        assert_eq!(decode_aes(&k32(), e32[i]).unwrap(), *t);
        assert_eq!(encode_aes_hex_upper(&k16(), t).unwrap(), ehex[i]);
    }
    assert_eq!(
        encode_aes(&[0; 20], "x"),
        Err(CryptoError::InvalidKeyLength(20))
    );
}

#[test]
fn swift_golden_aes_decode_edge_cases() {
    let good = "Z0x+8454yr2c7JwSWCOmOQ==";
    let key = k16();
    assert_eq!(encode_aes(&key, "hello").unwrap(), good);
    assert_eq!(decode_aes(&key, good).unwrap(), "hello");
    assert_eq!(decode_aes(&key, &format!("  {good}\n")).unwrap(), "hello");
    // Missing padding is rejected even in ignore-unknown mode.
    assert_eq!(
        decode_aes(&key, "Z0x+8454yr2c7JwSWCOmOQ"),
        Err(CryptoError::InvalidBase64)
    );
    // Inner newline and junk characters are skipped.
    assert_eq!(
        decode_aes(&key, "Z0x+\n8454yr2c7JwSWCOmOQ==").unwrap(),
        "hello"
    );
    assert_eq!(
        decode_aes(&key, "!!Z0x+8454yr2c7JwSWCOmOQ==@@").unwrap(),
        "hello"
    );
    assert_eq!(decode_aes(&key, ""), Err(CryptoError::InvalidPadding));
    assert_eq!(decode_aes(&key, "AAAA"), Err(CryptoError::InvalidPadding));
    // URL-safe chars are dropped, not translated (the original `+`/`/`, if any, are gone).
    let urlsafe = good.replace('+', "-").replace('/', "_");
    assert_eq!(decode_aes(&key, &urlsafe), Err(CryptoError::InvalidBase64));
    assert_eq!(
        decode_aes(b"fedcba9876543210", good),
        Err(CryptoError::InvalidPadding)
    );
    assert_eq!(
        aes_cbc_crypt(&[7; 16], &key, &ZERO_IV, false),
        Err(CryptoError::InvalidPadding)
    );
    assert_eq!(
        aes_cbc_crypt(&[0; 16], &key, &[0; 8], true),
        Err(CryptoError::InvalidIvLength(8))
    );
    assert_eq!(
        hx(&aes_cbc_crypt("Việt".as_bytes(), &k32(), &iv(), true).unwrap()),
        "1c05044992c6909f32cbf6b49643095e"
    );
    // Block-aligned plaintext gets a full extra padding block; empty plaintext one block.
    assert_eq!(
        hx(&aes_cbc_crypt(&[1; 16], &key, &ZERO_IV, true).unwrap()),
        "29df02f4a5329427cd452d588b6711d81272c24a77a1a95311922c9a785597e4"
    );
    assert_eq!(
        hx(&aes_cbc_crypt(&[], &key, &ZERO_IV, true).unwrap()),
        "377222e061a924c591cd9c27ea163ed4"
    );
    let ct =
        hex::decode("29df02f4a5329427cd452d588b6711d81272c24a77a1a95311922c9a785597e4").unwrap();
    assert_eq!(
        aes_cbc_crypt(&ct, &key, &ZERO_IV, false).unwrap(),
        vec![1u8; 16]
    );
}

#[test]
fn swift_golden_parse_secret_key() {
    let seq = |n: u8| (0..n).collect::<Vec<u8>>();
    let cases: Vec<String> = vec![
        "0123456789abcdef".into(),
        "  0123456789abcdef\n".into(),
        b64(&seq(32)),
        b64(&seq(32))[..43].to_owned(),
        format!("{} ", &b64(&seq(32))[..43]),
        b64(&seq(16)),
        b64(&seq(24)),
        "short".into(),
        String::new(),
        "AAAAAAAAAAAAAAAAAAAAAA==".into(),
        "AAAAAAAAAAAAAAAAAAAAAA".into(),
        "AAAAAAAAAA\nAAAAAAAAAA==".into(),
        "0123456789abcdef0123456789abcdef".into(),
        "ép ép ép ép ép!".into(),
    ];
    let expected = [
        "30313233343536373839616263646566",
        "30313233343536373839616263646566",
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        "41414543417751464267634943516f4c4441304f4478415245684d554652595847426b6147787764486838",
        "41414543417751464267634943516f4c4441304f4478415245684d554652595847426b6147787764486838",
        "000102030405060708090a0b0c0d0e0f",
        "41414543417751464267634943516f4c4441304f4478415245684d5546525958",
        "73686f7274",
        "",
        "00000000000000000000000000000000",
        "41414141414141414141414141414141414141414141",
        "414141414141414141410a414141414141414141413d3d",
        "3031323334353637383961626364656630313233343536373839616263646566",
        "c3a97020c3a97020c3a97020c3a97020c3a97021",
    ];
    for (i, c) in cases.iter().enumerate() {
        assert_eq!(hx(&parse_secret_key(c)), expected[i], "case {i}");
    }
}

#[test]
fn swift_golden_cloud_keys_and_blob() {
    let key16 = b64(&[0x2A; 16]);
    let keys = [
        key16.clone(),
        b64(&[0x5C; 32]),
        "AQID".to_owned(),
        "!!!".to_owned(),
        String::new(),
        format!(" {key16}\n"),
        key16[..key16.len() - 2].to_owned(),
    ];
    let expected: [Result<&str, CryptoError>; 7] = [
        Ok("2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a"),
        Ok("5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c5c"),
        Err(CryptoError::InvalidKeyLength(3)),
        Err(CryptoError::InvalidBase64),
        Err(CryptoError::InvalidKeyLength(0)),
        Ok("2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a"),
        Err(CryptoError::InvalidBase64),
    ];
    for (k, e) in keys.iter().zip(expected) {
        assert_eq!(
            decode_cloud_key(k).map(|v| hx(&v)),
            e.map(str::to_owned),
            "{k}"
        );
    }
    let blob = "AQIDBAUGBwgJCgsMDQ4PECIYfFtTzcOs4GUy1j0s0vQ=";
    let iv: [u8; 16] = iv().try_into().unwrap();
    assert_eq!(
        encode_cloud_aes_with_iv(&key16, "Xin chào 😀", &iv).unwrap(),
        blob
    );
    assert_eq!(decode_cloud_aes(&key16, blob).unwrap(), "Xin chào 😀");
    for n in [16usize, 17, 32] {
        assert_eq!(
            decode_cloud_aes(&key16, &b64(&vec![0u8; n])),
            Err(CryptoError::InvalidPadding),
            "{n}"
        );
    }
}

#[test]
fn swift_golden_sign_key() {
    assert_eq!(
        sign_key("reqqr", &map(&[("b", "2"), ("a", "1"), ("imei", "abc")])),
        "7cf003fb0728751a123c799daec620b2"
    );
    assert_eq!(sign_key("t", &map(&[])), "ca3dbc26fac5255a20813cbee0510624");
    let login = map(&[
        ("zcid", "ABC"),
        ("params", "Xin chào"),
        ("type", "30"),
        ("client_version", "694"),
        ("enc_ver", "v2"),
        ("zcid_ext", "ff00"),
    ]);
    assert_eq!(
        sign_key("getlogininfo", &login),
        "c1fe11b19f793f57028ca66f582dfab7"
    );
    // Mixed-case / digit / underscore / non-ASCII keys (byte order equals Swift order here).
    let mixed = map(&[
        ("B", "1"),
        ("a", "2"),
        ("_", "3"),
        ("Z", "4"),
        ("é", "5"),
        ("10", "6"),
        ("9", "7"),
    ]);
    assert_eq!(sign_key("x", &mixed), "ec93af6c82ef902e0652533b2ae4a835");
    let prefixes = map(&[("ab", "1"), ("a", "2"), ("a_", "3"), ("aB", "4")]);
    assert_eq!(sign_key("x", &prefixes), "49899b073830085b33a32ae508a6bcd6");
}

#[test]
fn swift_golden_encrypt_password() {
    let enc = encrypt_password("84901234567", "abcdef-12345", "Mật khẩu 123", "k3j9x0aa");
    assert_eq!(enc.unwrap(), "rAt8nxvaehyq06sszOcuYuuZVrv1dR3q6VIvEbq8v2w=");
    assert_eq!(
        encrypt_password("", "", "", "").unwrap(),
        "NuQTTIx9GnlISNxT/99fpA=="
    );
}

#[test]
fn swift_golden_param_cipher() {
    let pc =
        ParamCipher::with_zcid_ext("30", "imei-xyz-123", 1_700_000_000_000, "5be85c628d".into())
            .unwrap();
    assert_eq!(
        pc.zcid(),
        "ED3558BE77FD013C5C15B8029C037490A60ECB3D4783AB73252D7B11AC4C2E22"
    );
    assert_eq!(pc.zcid_ext(), "5be85c628d");
    assert_eq!(pc.encrypt_key(), "B95C9426E35B7F0351B02ECC1BD53B37");
    assert_eq!(
        pc.encrypt_payload_str(r#"{"a":"Việt"}"#).unwrap(),
        "MHk/YpYtnBG02oA4hsinFA=="
    );
    let payload: Value = serde_json::from_str(r#"{"k":"v"}"#).unwrap();
    let signed = pc
        .build_signed_params("30", "694", &payload, "getlogininfo")
        .unwrap();
    let joined: Vec<String> = signed.iter().map(|(k, v)| format!("{k}={v}")).collect();
    assert_eq!(
        joined.join("&"),
        "client_version=694&enc_ver=v2&params=dEbpBYDYRUXcDVTnfO4ZUw==&signkey=7557455d912e489a38480fba9109d34d&type=30&zcid=ED3558BE77FD013C5C15B8029C037490A60ECB3D4783AB73252D7B11AC4C2E22&zcid_ext=5be85c628d"
    );
    let c0 = ParamCipher::with_zcid_ext("30", "imei", 0, "x".into()).unwrap();
    assert_eq!(c0.zcid(), "B81147BF86B5ABF87B612C22ED212ED0");
    let c1 = ParamCipher::with_zcid_ext("24", "ünï😀", 1_731_849_600_123, "x".into()).unwrap();
    assert_eq!(
        c1.zcid(),
        "4DE04CA9E70795D3BB77A2CB30848A1F1A8B2FC0430028A69BB0478D7B8FD375"
    );
}

#[test]
fn swift_golden_percent_decode() {
    let cases = [
        "a%20b",
        "%41%42%4a%4A",
        "100%",
        "%4",
        "%zz",
        "x%2",
        "%2",
        "%C3%A9%F0%9F%98%80",
        "%E0%A4",
        "+ plus",
        "%%41",
        "",
    ];
    let expected = [
        "612062",
        "41424a4a",
        "31303025",
        "2534",
        "257a7a",
        "782532",
        "2532",
        "c3a9f09f9880",
        "efbfbd",
        "2b20706c7573",
        "2541",
        "",
    ];
    for (i, c) in cases.iter().enumerate() {
        assert_eq!(hx(percent_decode(c).as_bytes()), expected[i], "case {i}");
    }
}

fn gcm_key() -> Vec<u8> {
    (0..32u32).map(|i| ((i * 7) & 0xFF) as u8).collect()
}

fn gcm_aad() -> Vec<u8> {
    (0..16u8).map(|i| i + 17).collect()
}

const GCM_PLAIN: &str = r#"{"error_code":0,"data":{"msgId":9876543210987654321}}"#;

#[test]
fn swift_golden_gcm16() {
    let key = gcm_key();
    for (name, len, full, empty) in [
        (
            "k32",
            32,
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20610a165ff9c8b5a8c1500645349df6aaa84c54c22b936c7f746ec7e3e6e8719faadb17b28fd376326edad950779c7032453329187bdb36322f104b7243f1d0e73965bf1256",
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f206cdee907f58317689aefd4a40f1b6a5f",
        ),
        (
            "k16",
            16,
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20d27f1159da1a2a59b33ba5c179edd6be489bf8b8f1e8729bb4180742e96fe06dae85c1382a2e8fd00276a23cce60f187244a68a3fbe9c20050fda9e4f20c85e5fee5289d10",
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20ecc9fb1d9de0b04f186457a4cab12d3a",
        ),
        (
            "k24",
            24,
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f205797b3b27a1243655815e8e7b8dcb8c1b44c60ac378ce6bc56a08b33b9fbda8c201047826d02eb1c902f72487dbb52d19ee72d979af9c8b8c7fa9ae3c875c38249f25e0191",
            "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20b0bcd545a7d1899d09bc0037d3023238",
        ),
    ] {
        let k = &key[..len];
        let sealed = gcm_encrypt16(k, GCM_PLAIN.as_bytes(), &iv(), &gcm_aad()).unwrap();
        assert_eq!(hx(&sealed), full, "{name}");
        assert_eq!(
            gcm_decrypt16(k, &sealed).unwrap(),
            GCM_PLAIN.as_bytes(),
            "{name}"
        );
        let sealed_empty = gcm_encrypt16(k, b"", &iv(), &gcm_aad()).unwrap();
        assert_eq!(hx(&sealed_empty), empty, "{name}");
        assert_eq!(
            gcm_decrypt16(k, &sealed_empty).unwrap(),
            Vec::<u8>::new(),
            "{name}"
        );
    }
    let viet = gcm_encrypt16(&key, "Chào 😀".as_bytes(), &iv(), &gcm_aad()).unwrap();
    assert_eq!(
        hx(&viet),
        "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f205940b08de48737683abf89b8fe7d47de52902fa34f51d35074f4"
    );
    assert_eq!(
        gcm_encrypt16(&key, b"x", &[0; 12], &gcm_aad()),
        Err(CryptoError::InvalidGcmBlob(12))
    );
    assert_eq!(
        gcm_encrypt16(&[0; 20], b"x", &iv(), &gcm_aad()),
        Err(CryptoError::InvalidKeyLength(20))
    );
    assert_eq!(
        gcm_decrypt16(&key, &[0; 47]),
        Err(CryptoError::InvalidGcmBlob(47))
    );
    assert_eq!(
        gcm_decrypt16(&key, &[0; 48]),
        Err(CryptoError::GcmAuthFailed)
    );
}

#[test]
fn swift_golden_ws_frame_errors_and_plain() {
    assert_eq!(
        decrypt_ws_frame(None, 0, "héllo").unwrap(),
        "héllo".as_bytes()
    );
    assert_eq!(
        decrypt_ws_frame(None, 9, "x"),
        Err(CryptoError::UnsupportedEncryption(9))
    );
    assert_eq!(
        decrypt_ws_frame(None, 2, "x"),
        Err(CryptoError::MissingCipherKey)
    );
    assert_eq!(
        decrypt_ws_frame(Some(&[]), 3, "x"),
        Err(CryptoError::MissingCipherKey)
    );
    assert_eq!(
        decrypt_ws_frame(None, 1, "AAAA"),
        Err(CryptoError::InflateFailed)
    );
    assert_eq!(decrypt_ws_frame(None, 1, "").unwrap(), Vec::<u8>::new());
}

fn zlib_fixtures() -> Vec<Vec<u8>> {
    // Produced with Python zlib/gzip (see scratch gen); order matches the Swift probe.
    include_str!("inflate_fixtures.txt")
        .split_whitespace()
        .map(|h| hex::decode(h).unwrap())
        .collect()
}

#[test]
fn swift_golden_inflate() {
    let f = zlib_fixtures();
    let plain = hex::decode("7b226572726f725f636f6465223a302c2264617461223a7b226d73674964223a393837363534333231303938373635343332317d7d").unwrap();
    assert_eq!(plain, GCM_PLAIN.as_bytes());
    // zlib, gzip, raw deflate, zlib + trailing junk, and a gzip with a second member all decode.
    for i in [0, 1, 2, 3, 13] {
        assert_eq!(inflate_zlib_or_gzip(&f[i]).unwrap(), plain, "fixture {i}");
    }
    // Truncated, empty-output, and garbage streams fail (empty output is an error).
    for i in [4, 5, 11] {
        assert_eq!(
            inflate_zlib_or_gzip(&f[i]),
            Err(CryptoError::InflateFailed),
            "fixture {i}"
        );
    }
    assert_eq!(inflate_zlib_or_gzip(&[]).unwrap(), Vec::<u8>::new());
    assert_eq!(
        hx(&inflate_zlib_or_gzip(&f[6]).unwrap()),
        "6161616161616161616161616161616161616161"
    );
    assert_eq!(
        hx(&inflate_zlib_or_gzip(&f[9]).unwrap()),
        "6161616161616161616161616161616161616161"
    );
    assert_eq!(
        hx(&inflate_zlib_or_gzip(&f[10]).unwrap()),
        "6161616161616161616161616161616161616161"
    );
    assert_eq!(
        hx(&inflate_zlib_or_gzip(&f[12]).unwrap()),
        "58696e206368c3a06f20f09f9880"
    );
    // Size cap: output longer than the cap fails, equal to the cap succeeds.
    assert_eq!(inflate_zlib_or_gzip_max(&f[7], 4).unwrap(), b"abcd");
    assert_eq!(inflate_zlib_or_gzip_max(&f[8], 10).unwrap(), b"abcdefghij");
    for (i, cap) in [
        (8usize, 4usize),
        (0, 4),
        (0, 10),
        (6, 10),
        (9, 10),
        (10, 10),
        (12, 10),
    ] {
        assert_eq!(
            inflate_zlib_or_gzip_max(&f[i], cap),
            Err(CryptoError::InflateFailed),
            "{i}/{cap}"
        );
    }
}
