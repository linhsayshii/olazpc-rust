/* In-process libzproto_wasm host for Phone -> Mac Sync v2 (JavaScriptCore, zero Node). */
(function (globalScope) {
  'use strict';

  const zproto = {};
  const webpackStub = {
    d: function (obj, name, getter) {
      Object.defineProperty(obj, name, { get: getter, enumerable: true });
    }
  };
  const fakeModule = { exports: zproto };

  (function (module, exports, s) {
    (function (e, r) {
      let i;
      s.d(zproto, "g", function () { return w; });
      s.d(zproto, "l", function () { return _; });
      s.d(zproto, "h", function () { return C; });
      s.d(zproto, "j", function () { return T; });
      s.d(zproto, "k", function () { return E; });
      s.d(zproto, "i", function () { return R; });
      s.d(zproto, "e", function () { return k; });
      s.d(zproto, "c", function () { return O; });
      s.d(zproto, "d", function () { return N; });
      s.d(zproto, "f", function () { return F; });
      s.d(zproto, "a", function () { return z; });

      const n = new Array(128).fill(void 0);
      function a(idx) { return n[idx]; }
      n.push(void 0, null, !0, !1);
      let o = n.length;
      function c(val) {
        if (o === n.length) n.push(n.length + 1);
        const slot = o;
        o = n[slot];
        n[slot] = val;
        return slot;
      }
      function l(fn, args) {
        try { return fn.apply(this, args); }
        catch (err) { i.__wbindgen_export_0(c(err)); }
      }

      const d = typeof TextDecoder !== "undefined"
        ? new TextDecoder("utf-8", { ignoreBOM: !0, fatal: !0 })
        : { decode: function () { throw Error("TextDecoder not available"); } };
      if (typeof TextDecoder !== "undefined") d.decode();

      let u = null;
      function h() {
        if (u === null || u.byteLength === 0) u = new Uint8Array(i.memory.buffer);
        return u;
      }
      function g(ptr, len) {
        ptr >>>= 0;
        return d.decode(h().subarray(ptr, ptr + len));
      }
      function p(idx) {
        const val = a(idx);
        (function (x) { if (x >= 132) { n[x] = o; o = x; } })(idx);
        return val;
      }

      let m = 0;
      const y = typeof TextEncoder !== "undefined"
        ? new TextEncoder("utf-8")
        : { encode: function () { throw Error("TextEncoder not available"); } };
      const f = typeof y.encodeInto === "function"
        ? function (str, dst) { return y.encodeInto(str, dst); }
        : function (str, dst) {
            const enc = y.encode(str);
            dst.set(enc);
            return { read: str.length, written: enc.length };
          };

      function b(str, malloc, realloc) {
        if (realloc === void 0) {
          const enc = y.encode(str);
          const ptr = malloc(enc.length, 1) >>> 0;
          h().subarray(ptr, ptr + enc.length).set(enc);
          m = enc.length;
          return ptr;
        }
        let len = str.length;
        let ptr = malloc(len, 1) >>> 0;
        const mem = h();
        let offset = 0;
        for (; offset < len; offset++) {
          const code = str.charCodeAt(offset);
          if (code > 127) break;
          mem[ptr + offset] = code;
        }
        if (offset !== len) {
          if (offset !== 0) str = str.slice(offset);
          ptr = realloc(ptr, len, len = offset + 3 * str.length, 1) >>> 0;
          const view = h().subarray(ptr + offset, ptr + len);
          offset += f(str, view).written;
          ptr = realloc(ptr, len, offset, 1) >>> 0;
        }
        m = offset;
        return ptr;
      }

      let S = null;
      function M() {
        if (S === null || S.buffer.detached === !0 || (S.buffer.detached === void 0 && S.buffer !== i.memory.buffer)) {
          S = new DataView(i.memory.buffer);
        }
        return S;
      }
      function v(val) { return val == null; }

      function w(level, loggerObj) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          i.zprotoLoggerInitialize(ret, level, c(loggerObj));
          const errIdx = M().getInt32(ret + 0, !0);
          if (M().getInt32(ret + 4, !0)) throw p(errIdx);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function I(bytes, malloc) {
        const ptr = malloc(bytes.length, 1) >>> 0;
        h().set(bytes, ptr);
        m = bytes.length;
        return ptr;
      }

      function _(a0, a1, a2) {
        let rPtr, rLen;
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          const p2 = I(a2, i.__wbindgen_export_2), l2 = m;
          i.zprotoSync2GetSessionId(ret, p0, l0, p1, l1, p2, l2);
          let ptr = M().getInt32(ret + 0, !0);
          let len = M().getInt32(ret + 4, !0);
          const errIdx = M().getInt32(ret + 8, !0);
          const isErr = M().getInt32(ret + 12, !0);
          if (isErr) { ptr = 0; len = 0; throw p(errIdx); }
          rPtr = ptr; rLen = len;
          return g(ptr, len);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
          i.__wbindgen_export_1(rPtr, rLen, 1);
        }
      }

      function C(a0, a1, a2, a3, a4, a5) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          const p2 = I(a2, i.__wbindgen_export_2), l2 = m;
          const p3 = I(a3, i.__wbindgen_export_2), l3 = m;
          const p4 = I(a4, i.__wbindgen_export_2), l4 = m;
          const p5 = v(a5) ? 0 : b(a5, i.__wbindgen_export_2, i.__wbindgen_export_3);
          const l5 = m;
          i.zprotoSync2CreateMetadataCipher(ret, p0, l0, p1, l1, p2, l2, p3, l3, p4, l4, p5, l5);
          const ptr = M().getInt32(ret + 0, !0);
          const errIdx = M().getInt32(ret + 4, !0);
          if (M().getInt32(ret + 8, !0)) throw p(errIdx);
          return W.__wrap(ptr);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function T(a0, a1, a2, a3, a4) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          const p2 = I(a2, i.__wbindgen_export_2), l2 = m;
          const p3 = I(a3, i.__wbindgen_export_2), l3 = m;
          const p4 = v(a4) ? 0 : b(a4, i.__wbindgen_export_2, i.__wbindgen_export_3);
          const l4 = m;
          i.zprotoSync2DecryptMetadata(ret, p0, l0, p1, l1, p2, l2, p3, l3, p4, l4);
          const ptr = M().getInt32(ret + 0, !0);
          const errIdx = M().getInt32(ret + 4, !0);
          if (M().getInt32(ret + 8, !0)) throw p(errIdx);
          return G.__wrap(ptr);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function E(a0, a1) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          i.zprotoSync2EncryptMessage(ret, p0, l0, p1, l1);
          const ptr = M().getInt32(ret + 0, !0);
          const errIdx = M().getInt32(ret + 4, !0);
          if (M().getInt32(ret + 8, !0)) throw p(errIdx);
          return B.__wrap(ptr);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function R(a0, a1) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          i.zprotoSync2DecryptMessage(ret, p0, l0, p1, l1);
          const ptr = M().getInt32(ret + 0, !0);
          const errIdx = M().getInt32(ret + 4, !0);
          if (M().getInt32(ret + 8, !0)) throw p(errIdx);
          return L.__wrap(ptr);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function k() {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          i.zprotoEd25519GenerateKeyPair(ret);
          const ptr = M().getInt32(ret + 0, !0);
          const errIdx = M().getInt32(ret + 4, !0);
          if (M().getInt32(ret + 8, !0)) throw p(errIdx);
          return A.__wrap(ptr);
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function D(ptr, len) {
        ptr >>>= 0;
        return h().subarray(ptr, ptr + len);
      }

      function O(a0, a1) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          i.zprotoEd25519CalculateAgreement(ret, p0, l0, p1, l1);
          const ptr = M().getInt32(ret + 0, !0);
          const len = M().getInt32(ret + 4, !0);
          const errIdx = M().getInt32(ret + 8, !0);
          if (M().getInt32(ret + 12, !0)) throw p(errIdx);
          const slice = D(ptr, len).slice();
          i.__wbindgen_export_1(ptr, len, 1);
          return slice;
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function N(a0, a1) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          i.zprotoEd25519CalculateSignature(ret, p0, l0, p1, l1);
          const ptr = M().getInt32(ret + 0, !0);
          const len = M().getInt32(ret + 4, !0);
          const errIdx = M().getInt32(ret + 8, !0);
          if (M().getInt32(ret + 12, !0)) throw p(errIdx);
          const slice = D(ptr, len).slice();
          i.__wbindgen_export_1(ptr, len, 1);
          return slice;
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      function F(a0, a1, a2) {
        try {
          const ret = i.__wbindgen_add_to_stack_pointer(-16);
          const p0 = I(a0, i.__wbindgen_export_2), l0 = m;
          const p1 = I(a1, i.__wbindgen_export_2), l1 = m;
          const p2 = I(a2, i.__wbindgen_export_2), l2 = m;
          i.zprotoEd25519VerifySignature(ret, p0, l0, p1, l1, p2, l2);
          const ok = M().getInt32(ret + 0, !0);
          const errIdx = M().getInt32(ret + 4, !0);
          if (M().getInt32(ret + 8, !0)) throw p(errIdx);
          return ok !== 0;
        } finally {
          i.__wbindgen_add_to_stack_pointer(16);
        }
      }

      const z = Object.freeze({ Error: 1, 1: "Error", Warn: 2, 2: "Warn", Info: 3, 3: "Info", Debug: 4, 4: "Debug", Trace: 5, 5: "Trace" });
      const P = typeof FinalizationRegistry === "undefined"
        ? { register: function () {}, unregister: function () {} }
        : new FinalizationRegistry(function (ptr) { i.__wbg_zprotoed25519keypair_free(ptr >>> 0, 1); });

      class A {
        static __wrap(ptr) {
          ptr >>>= 0;
          const obj = Object.create(A.prototype);
          obj.__wbg_ptr = ptr;
          P.register(obj, obj.__wbg_ptr, obj);
          return obj;
        }
        __destroy_into_raw() {
          const ptr = this.__wbg_ptr;
          this.__wbg_ptr = 0;
          P.unregister(this);
          return ptr;
        }
        free() {
          const ptr = this.__destroy_into_raw();
          i.__wbg_zprotoed25519keypair_free(ptr, 0);
        }
        get publicKey() { return p(i.zprotoed25519keypair_publicKey(this.__wbg_ptr)); }
        get privateKey() { return p(i.zprotoed25519keypair_privateKey(this.__wbg_ptr)); }
      }

      const x = typeof FinalizationRegistry === "undefined"
        ? { register: function () {}, unregister: function () {} }
        : new FinalizationRegistry(function (ptr) { i.__wbg_zprotosyncmessagedecrypted_free(ptr >>> 0, 1); });

      class L {
        static __wrap(ptr) {
          ptr >>>= 0;
          const obj = Object.create(L.prototype);
          obj.__wbg_ptr = ptr;
          x.register(obj, obj.__wbg_ptr, obj);
          return obj;
        }
        __destroy_into_raw() {
          const ptr = this.__wbg_ptr;
          this.__wbg_ptr = 0;
          x.unregister(this);
          return ptr;
        }
        free() {
          const ptr = this.__destroy_into_raw();
          i.__wbg_zprotosyncmessagedecrypted_free(ptr, 0);
        }
        get sessionId() { return p(i.zprotosyncmessagedecrypted_sessionId(this.__wbg_ptr)); }
        get plaintext() { return p(i.zprotosyncmessagedecrypted_plaintext(this.__wbg_ptr)); }
      }

      const j = typeof FinalizationRegistry === "undefined"
        ? { register: function () {}, unregister: function () {} }
        : new FinalizationRegistry(function (ptr) { i.__wbg_zprotosyncmessageencrypted_free(ptr >>> 0, 1); });

      class B {
        static __wrap(ptr) {
          ptr >>>= 0;
          const obj = Object.create(B.prototype);
          obj.__wbg_ptr = ptr;
          j.register(obj, obj.__wbg_ptr, obj);
          return obj;
        }
        __destroy_into_raw() {
          const ptr = this.__wbg_ptr;
          this.__wbg_ptr = 0;
          j.unregister(this);
          return ptr;
        }
        free() {
          const ptr = this.__destroy_into_raw();
          i.__wbg_zprotosyncmessageencrypted_free(ptr, 0);
        }
        get sessionId() { return p(i.zprotosyncmessagedecrypted_sessionId(this.__wbg_ptr)); }
        get ciphertext() { return p(i.zprotosyncmessagedecrypted_plaintext(this.__wbg_ptr)); }
      }

      const U = typeof FinalizationRegistry === "undefined"
        ? { register: function () {}, unregister: function () {} }
        : new FinalizationRegistry(function (ptr) { i.__wbg_zprotosyncmetadatadecrypted_free(ptr >>> 0, 1); });

      class G {
        static __wrap(ptr) {
          ptr >>>= 0;
          const obj = Object.create(G.prototype);
          obj.__wbg_ptr = ptr;
          U.register(obj, obj.__wbg_ptr, obj);
          return obj;
        }
        __destroy_into_raw() {
          const ptr = this.__wbg_ptr;
          this.__wbg_ptr = 0;
          U.unregister(this);
          return ptr;
        }
        free() {
          const ptr = this.__destroy_into_raw();
          i.__wbg_zprotosyncmetadatadecrypted_free(ptr, 0);
        }
        get sessionId() { return p(i.zprotosyncmetadatadecrypted_sessionId(this.__wbg_ptr)); }
        get plaintext() { return p(i.zprotosyncmetadatadecrypted_plaintext(this.__wbg_ptr)); }
        get senderIdentity() { return p(i.zprotosyncmetadatadecrypted_senderIdentity(this.__wbg_ptr)); }
        get sessionRecord() { return p(i.zprotosyncmetadatadecrypted_sessionRecord(this.__wbg_ptr)); }
      }

      const q = typeof FinalizationRegistry === "undefined"
        ? { register: function () {}, unregister: function () {} }
        : new FinalizationRegistry(function (ptr) { i.__wbg_zprotosyncmetadataencrypted_free(ptr >>> 0, 1); });

      class W {
        static __wrap(ptr) {
          ptr >>>= 0;
          const obj = Object.create(W.prototype);
          obj.__wbg_ptr = ptr;
          q.register(obj, obj.__wbg_ptr, obj);
          return obj;
        }
        __destroy_into_raw() {
          const ptr = this.__wbg_ptr;
          this.__wbg_ptr = 0;
          q.unregister(this);
          return ptr;
        }
        free() {
          const ptr = this.__destroy_into_raw();
          i.__wbg_zprotosyncmetadataencrypted_free(ptr, 0);
        }
        get sessionId() { return p(i.zprotosyncmetadatadecrypted_sessionId(this.__wbg_ptr)); }
        get ciphertext() { return p(i.zprotosyncmetadatadecrypted_plaintext(this.__wbg_ptr)); }
        get receiverIdentity() { return p(i.zprotosyncmetadatadecrypted_senderIdentity(this.__wbg_ptr)); }
        get sessionRecord() { return p(i.zprotosyncmetadatadecrypted_sessionRecord(this.__wbg_ptr)); }
      }

      function Q() {
        const imp = { wbg: {} };
        imp.wbg.__wbg_apply_36be6a55257c99bf = function () { return l(function (fn, th, ar) { return c(a(fn).apply(a(th), a(ar))); }, arguments); };
        imp.wbg.__wbg_buffer_609cc3eee51ed158 = function (idx) { return c(a(idx).buffer); };
        imp.wbg.__wbg_call_672a4d21634d4a24 = function () { return l(function (fn, th) { return c(a(fn).call(a(th))); }, arguments); };
        imp.wbg.__wbg_call_7cccdd69e0791ae2 = function () { return l(function (fn, th, a1) { return c(a(fn).call(a(th), a(a1))); }, arguments); };
        imp.wbg.__wbg_crypto_ed58b8e10a292839 = function (idx) { return c(a(idx).crypto); };
        imp.wbg.__wbg_error_7534b8e9a36f1ab4 = function (ptr, len) { try {} finally { i.__wbindgen_export_1(ptr, len, 1); } };
        imp.wbg.__wbg_getRandomValues_bcb4912f16000dc4 = function () { return l(function (cr, arr) { a(cr).getRandomValues(a(arr)); }, arguments); };
        imp.wbg.__wbg_msCrypto_0a36e2ec3a343d26 = function (idx) { return c(a(idx).msCrypto); };
        imp.wbg.__wbg_new_405e22f390576ce2 = function () { return c(new Object()); };
        imp.wbg.__wbg_new_78feb108b6472713 = function () { return c(new Array()); };
        imp.wbg.__wbg_new_8a6f238a6ece86ea = function () { return c(new Error()); };
        imp.wbg.__wbg_new_a12002a7f91c75be = function (idx) { return c(new Uint8Array(a(idx))); };
        imp.wbg.__wbg_newnoargs_105ed471475aaf50 = function (ptr, len) { return c(new Function(g(ptr, len))); };
        imp.wbg.__wbg_newwithbyteoffsetandlength_d97e637ebe145a9a = function (buf, off, len) { return c(new Uint8Array(a(buf), off >>> 0, len >>> 0)); };
        imp.wbg.__wbg_newwithlength_a381634e90c276d4 = function (len) { return c(new Uint8Array(len >>> 0)); };
        imp.wbg.__wbg_node_02999533c4ea02e3 = function (idx) { return c(a(idx).node); };
        imp.wbg.__wbg_process_5c1d670bc53614b8 = function (idx) { return c(a(idx).process); };
        imp.wbg.__wbg_push_737cfc8c1432c2c6 = function (arr, item) { return a(arr).push(a(item)); };
        imp.wbg.__wbg_randomFillSync_ab2cfe79ebbf2740 = function () { return l(function (cr, arr) { a(cr).randomFillSync(p(arr)); }, arguments); };
        imp.wbg.__wbg_require_79b1e9274cde3c87 = function () { return l(function () { return c(e.require); }, arguments); };
        imp.wbg.__wbg_set_3f1d0b984ed272ed = function (obj, k, val) { a(obj)[p(k)] = p(val); };
        imp.wbg.__wbg_set_65595bdd868b3009 = function (dst, src, off) { a(dst).set(a(src), off >>> 0); };
        imp.wbg.__wbg_stack_0ed75d68575b0f3c = function (ret, err) {
          const ptr = b(a(err).stack || '', i.__wbindgen_export_2, i.__wbindgen_export_3);
          const len = m;
          M().setInt32(ret + 4, len, !0);
          M().setInt32(ret + 0, ptr, !0);
        };
        imp.wbg.__wbg_static_accessor_GLOBAL_88a902d13a557d07 = function () { const val = typeof r === "undefined" ? null : r; return v(val) ? 0 : c(val); };
        imp.wbg.__wbg_static_accessor_GLOBAL_THIS_56578be7e9f832b0 = function () { const val = typeof globalThis === "undefined" ? null : globalThis; return v(val) ? 0 : c(val); };
        imp.wbg.__wbg_static_accessor_SELF_37c5d418e4bf5819 = function () { const val = typeof self === "undefined" ? null : self; return v(val) ? 0 : c(val); };
        imp.wbg.__wbg_static_accessor_WINDOW_5de37043a91a9c40 = function () { const val = typeof window === "undefined" ? null : window; return v(val) ? 0 : c(val); };
        imp.wbg.__wbg_subarray_aa9065fa9dc5df96 = function (arr, begin, end) { return c(a(arr).subarray(begin >>> 0, end >>> 0)); };
        imp.wbg.__wbg_versions_c71aa1626a93e0a1 = function (idx) { return c(a(idx).versions); };
        imp.wbg.__wbindgen_is_function = function (idx) { return typeof a(idx) === "function"; };
        imp.wbg.__wbindgen_is_object = function (idx) { const val = a(idx); return typeof val === "object" && val !== null; };
        imp.wbg.__wbindgen_is_string = function (idx) { return typeof a(idx) === "string"; };
        imp.wbg.__wbindgen_is_undefined = function (idx) { return typeof a(idx) === "undefined"; };
        imp.wbg.__wbindgen_memory = function () { return c(i.memory); };
        imp.wbg.__wbindgen_number_new = function (num) { return c(num); };
        imp.wbg.__wbindgen_object_clone_ref = function (idx) { return c(a(idx)); };
        imp.wbg.__wbindgen_object_drop_ref = function (idx) { p(idx); };
        imp.wbg.__wbindgen_string_new = function (ptr, len) { return c(g(ptr, len)); };
        imp.wbg.__wbindgen_throw = function (ptr, len) { throw new Error(g(ptr, len)); };
        return imp;
      }

      function initWasm(wasmBytes) {
        if (i !== void 0) return i;
        const imports = Q();
        const wasmModule = new WebAssembly.Module(wasmBytes);
        const instance = new WebAssembly.Instance(wasmModule, imports);
        i = instance.exports;
        initWasm.__wbindgen_wasm_module = wasmModule;
        S = null;
        u = null;
        return i;
      }

      zproto.b = initWasm;
    }).call(globalScope, module, globalScope);
  })(fakeModule, zproto, webpackStub);

  let wasmReady = false;

  const toU8 = (x) => {
    if (x == null) return null;
    if (x instanceof Uint8Array) return x;
    if (ArrayBuffer.isView(x)) return new Uint8Array(x.buffer, x.byteOffset, x.byteLength);
    if (x instanceof ArrayBuffer) return new Uint8Array(x);
    return new Uint8Array(x);
  };

  const toB64 = (u8) => {
    let bin = '';
    for (let i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
    return btoa(bin);
  };

  const splitRecords = (u8) => {
    const records = [];
    const view = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
    let offset = 0;
    while (offset + 4 <= u8.byteLength) {
      const len = view.getUint32(offset, true);
      if (len === 0 || offset + 4 + len > u8.byteLength) break;
      records.push(u8.subarray(offset + 4, offset + 4 + len));
      offset += 4 + len;
    }
    return (offset === u8.byteLength && records.length > 0) ? records : [u8];
  };

  globalScope.ZaloZprotoSync = {
    _zproto: zproto,

    init(wasmBuffer) {
      if (wasmReady) return true;
      const bytes = toU8(wasmBuffer);
      if (!bytes || bytes.byteLength < 8) {
        throw new Error('Invalid zproto wasm bytes');
      }
      zproto.b(bytes);
      wasmReady = true;
      return true;
    },

    generateKeys() {
      if (!wasmReady) throw new Error('zproto wasm not initialized');
      const ik = zproto.e();
      const ek = zproto.e();
      try {
        const ikPub = toU8(ik.publicKey).slice();
        const ikPriv = toU8(ik.privateKey).slice();
        const ekPub = toU8(ek.publicKey).slice();
        const ekPriv = toU8(ek.privateKey).slice();
        return {
          ikPubB64: toB64(ikPub),
          ikPub: ikPub,
          ikPriv: ikPriv,
          ekPubB64: toB64(ekPub),
          ekPriv: ekPriv,
        };
      } finally {
        ik.free();
        ek.free();
      }
    },

    decryptBatch(batchBuffer, ikPubBuf, ikPrivBuf, ekPrivBuf, sessionBufOrNull) {
      if (!wasmReady) throw new Error('zproto wasm not initialized');
      const batch = toU8(batchBuffer);
      const ikPub = toU8(ikPubBuf);
      const ikPriv = toU8(ikPrivBuf);
      const ekPriv = toU8(ekPrivBuf);
      let session = sessionBufOrNull ? toU8(sessionBufOrNull).slice() : null;

      const records = [];
      let metaCount = 0;
      let msgCount = 0;
      let failedCount = 0;

      const tryMeta = (record) => {
        const res = zproto.j(record, ikPub, ikPriv, ekPriv, null);
        try {
          session = toU8(res.sessionRecord).slice();
          const plain = toU8(res.plaintext).slice();
          records.push({ kind: 1, plain: plain });
          metaCount++;
        } finally {
          res.free();
        }
      };

      const tryMessage = (record) => {
        if (!session) throw new Error('no session');
        const res = zproto.i(record, session);
        try {
          const plain = toU8(res.plaintext).slice();
          records.push({ kind: 2, plain: plain });
          msgCount++;
        } finally {
          res.free();
        }
      };

      for (const rec of splitRecords(batch)) {
        const order = session !== null ? [tryMessage, tryMeta] : [tryMeta, tryMessage];
        let ok = false;
        for (const attempt of order) {
          try {
            attempt(rec);
            ok = true;
            break;
          } catch (_) {
            /* try the other kind */
          }
        }
        if (!ok) failedCount++;
      }

      return {
        session: session,
        records: records,
        metaCount: metaCount,
        msgCount: msgCount,
        failedCount: failedCount,
      };
    },

    createTestRoundTripBatch(receiverIkPubBuf, receiverEkPubBuf, metaPlainBuf, msgPlainBuf) {
      if (!wasmReady) throw new Error('zproto wasm not initialized');
      const senderIk = zproto.e();
      let metaEnc = null;
      let msgEnc = null;
      try {
        const sIkPub = toU8(senderIk.publicKey).slice();
        const sIkPriv = toU8(senderIk.privateKey).slice();
        metaEnc = zproto.h(
          toU8(metaPlainBuf),
          sIkPub,
          sIkPriv,
          toU8(receiverIkPubBuf),
          toU8(receiverEkPubBuf),
          null
        );
        const metaCipher = toU8(metaEnc.ciphertext).slice();
        const senderSession = toU8(metaEnc.sessionRecord).slice();
        msgEnc = zproto.k(toU8(msgPlainBuf), senderSession);
        const msgCipher = toU8(msgEnc.ciphertext).slice();

        const packed = new Uint8Array(4 + metaCipher.byteLength + 4 + msgCipher.byteLength);
        const dv = new DataView(packed.buffer);
        dv.setUint32(0, metaCipher.byteLength, true);
        packed.set(metaCipher, 4);
        dv.setUint32(4 + metaCipher.byteLength, msgCipher.byteLength, true);
        packed.set(msgCipher, 8 + metaCipher.byteLength);
        return packed;
      } finally {
        senderIk.free();
        if (metaEnc) metaEnc.free();
        if (msgEnc) msgEnc.free();
      }
    }
  };
})(globalThis);
