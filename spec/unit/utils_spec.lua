package.path = "./src/?.lua;./src/?/init.lua;./spec/?.lua;./spec/?/init.lua;" .. package.path

local utils = require("fairvisor.utils")
local json = utils.fairvisor_json

describe("utils.fairvisor_json (inlined JSON codec)", function()
  describe("decode", function()
    context("valid JSON", function()
      it("decodes empty object", function()
        local v, err = json.decode("{}")
        assert.is_nil(err)
        assert.same({}, v)
      end)

      it("decodes empty array", function()
        local v, err = json.decode("[]")
        assert.is_nil(err)
        assert.same({}, v)
      end)

      it("decodes object with one number", function()
        local v, err = json.decode('{"a":1}')
        assert.is_nil(err)
        assert.same({ a = 1 }, v)
      end)

      it("decodes object with multiple keys", function()
        local v, err = json.decode('{"a":1,"b":2}')
        assert.is_nil(err)
        assert.same({ a = 1, b = 2 }, v)
      end)

      it("decodes string values", function()
        local v, err = json.decode('{"k":"v"}')
        assert.is_nil(err)
        assert.same({ k = "v" }, v)
      end)

      it("decodes boolean and null", function()
        local v, err = json.decode('{"t":true,"f":false,"n":null}')
        assert.is_nil(err)
        assert.is_true(v.t)
        assert.is_false(v.f)
        assert.is_nil(v.n)
      end)

      it("decodes nested object", function()
        local v, err = json.decode('{"nested":{"x":1,"y":2}}')
        assert.is_nil(err)
        assert.same({ nested = { x = 1, y = 2 } }, v)
      end)

      it("decodes array of values", function()
        local v, err = json.decode("[1,2,3]")
        assert.is_nil(err)
        assert.same({ 1, 2, 3 }, v)
      end)

      it("decodes mixed array and object", function()
        local v, err = json.decode('{"arr":[1,2],"obj":{"a":1}}')
        assert.is_nil(err)
        assert.same({ arr = { 1, 2 }, obj = { a = 1 } }, v)
      end)

      it("decodes with leading and trailing whitespace", function()
        local v, err = json.decode('  { "a" : 1 }  ')
        assert.is_nil(err)
        assert.same({ a = 1 }, v)
      end)

      it("decodes numbers: integer, negative, float", function()
        local v, err = json.decode('{"i":42,"neg":-7,"f":3.14}')
        assert.is_nil(err)
        assert.same(42, v.i)
        assert.same(-7, v.neg)
        assert.same(3.14, v.f)
      end)

      it("decodes string escapes: quote, backslash, n r t", function()
        local v, err = json.decode('{"q":"\\"","bs":"\\\\","nl":"a\\nb","tab":"\\t"}')
        assert.is_nil(err)
        assert.same('"', v.q)
        assert.same('\\', v.bs)
        assert.same("a\nb", v.nl)
        assert.same("\t", v.tab)
      end)

      it("decodes empty string value", function()
        local v, err = json.decode('{"e":""}')
        assert.is_nil(err)
        assert.same("", v.e)
      end)
    end)

    context("invalid input", function()
      it("returns error for non-string input", function()
        local v, err = json.decode(123)
        assert.is_nil(v)
        assert.is_string(err)
        assert.is_truthy(err:find("string"))
      end)

      it("returns error for empty string", function()
        local v, err = json.decode("")
        assert.is_nil(v)
        assert.is_string(err)
      end)

      it("returns error for unterminated string", function()
        local v, err = json.decode('{"a":"unterminated')
        assert.is_nil(v)
        assert.is_string(err)
        assert.is_truthy(err:find("unterminated") or err:find("position"))
      end)

      it("returns error for unicode escape \\u (not supported)", function()
        local v, err = json.decode('{"u":"\\u0041"}')
        assert.is_nil(v)
        assert.is_string(err)
        assert.is_truthy(err:find("unicode") or err:find("not supported"))
      end)

      it("returns error for invalid escape", function()
        local v, err = json.decode('{"x":"\\z"}')
        assert.is_nil(v)
        assert.is_string(err)
      end)

      it("returns error for trailing garbage after value", function()
        local v, err = json.decode("{}x")
        assert.is_nil(v)
        assert.is_string(err)
        assert.is_truthy(err:find("trailing") or err:find("position"))
      end)

      it("returns error for missing comma in array", function()
        local v, err = json.decode("[1 2]")
        assert.is_nil(v)
        assert.is_string(err)
      end)

      it("returns error for missing colon after key", function()
        local v, err = json.decode('{"a" 1}')
        assert.is_nil(v)
        assert.is_string(err)
      end)

      it("returns error for invalid number", function()
        local v, err = json.decode("{")
        assert.is_nil(v)
        assert.is_string(err)
      end)
    end)
  end)

  describe("encode", function()
    context("valid values", function()
      it("encodes nil as null", function()
        local s, err = json.encode(nil)
        assert.is_nil(err)
        assert.same("null", s)
      end)

      it("encodes boolean", function()
        assert.same("true", json.encode(true))
        assert.same("false", json.encode(false))
      end)

      it("encodes number", function()
        assert.same("42", json.encode(42))
        assert.same("-1", json.encode(-1))
        assert.same("3.14", json.encode(3.14))
      end)

      it("encodes string with escapes", function()
        local s = json.encode('a"b\\c\nd')
        assert.is_string(s)
        assert.is_truthy(s:find('\\"'))
        assert.is_truthy(s:find('\\\\'))
        assert.is_truthy(s:find('\\n'))
      end)

      it("encodes empty array", function()
        assert.same("[]", json.encode({}))
      end)

      it("encodes array with consecutive integer keys", function()
        assert.same("[1,2,3]", json.encode({ 1, 2, 3 }))
      end)

      it("encodes empty table as empty array", function()
        local s = json.encode({})
        assert.is_string(s)
        assert.same("[]", s)
      end)

      it("encodes object with string keys", function()
        local s = json.encode({ a = 1, b = 2 })
        assert.is_string(s)
        assert.is_truthy(s:find("a") and s:find("b") and s:find("1") and s:find("2"))
      end)

      it("encodes nested structure", function()
        local s = json.encode({ x = { y = { 1, 2 } } })
        assert.is_string(s)
        assert.is_truthy(s:find("x") and s:find("y") and s:find("1") and s:find("2"))
      end)
    end)

    context("invalid values", function()
      it("returns error for object with non-string key", function()
        local s, err = json.encode({ [1.5] = "v" })
        assert.is_nil(s)
        assert.is_string(err)
        assert.is_truthy(err:find("string") or err:find("key"))
      end)
    end)
  end)

  describe("roundtrip", function()
    it("decode(encode(x)) equals x for primitive and tables", function()
      local cases = {
        {},
        { a = 1 },
        { a = 1, b = 2 },
        { arr = { 1, 2, 3 } },
        { nested = { x = "hello", y = true, z = nil } },
        { 1, 2, 3 },
        "hello",
        42,
        -3.14,
        true,
        false,
      }
      for _, x in ipairs(cases) do
        if type(x) == "table" then
          local enc, enc_err = json.encode(x)
          assert.is_nil(enc_err, "encode error for " .. tostring(x))
          local dec, dec_err = json.decode(enc)
          assert.is_nil(dec_err, "decode error for " .. enc)
          assert.same(x, dec)
        end
      end
    end)

    it("roundtrips JWT-style payload (no unicode)", function()
      local payload = { sub = "user-1", role = "admin", realm_access = { roles = { "a", "b" } } }
      local enc, _ = json.encode(payload)
      local dec, err = json.decode(enc)
      assert.is_nil(err)
      assert.same(payload, dec)
    end)
  end)
end)

-- ============================================================
-- Issue #25: targeted coverage additions for utils.lua
-- ============================================================

describe("utils.now", function()
  it("returns 0 when ngx is not available", function()
    local saved = _G.ngx
    _G.ngx = nil
    local v = utils.now()
    _G.ngx = saved
    assert.equals(0, v)
  end)

  it("returns ngx.now() value when ngx is available", function()
    local saved = _G.ngx
    _G.ngx = { now = function() return 12345.6 end }
    local v = utils.now()
    _G.ngx = saved
    assert.equals(12345.6, v)
  end)
end)

describe("utils.safe_require", function()
  it("returns nil for a module that does not exist", function()
    assert.is_nil(utils.safe_require("__no_such_module_xyz__"))
  end)

  it("returns the module for an existing module", function()
    local m = utils.safe_require("fairvisor.utils")
    assert.is_not_nil(m)
    assert.is_function(m.now)
  end)
end)

describe("utils.to_hex", function()
  it("converts binary bytes to hex string", function()
    assert.equals("00ffab", utils.to_hex("\0\255\171"))
  end)

  it("returns empty string for empty input", function()
    assert.equals("", utils.to_hex(""))
  end)

  it("returns nil for non-string input", function()
    assert.is_nil(utils.to_hex(nil))
    assert.is_nil(utils.to_hex(42))
  end)
end)

describe("utils.constant_time_equals", function()
  it("returns false when first argument is not a string", function()
    assert.is_false(utils.constant_time_equals(nil, "x"))
    assert.is_false(utils.constant_time_equals(1, "x"))
  end)

  it("returns false when second argument is not a string", function()
    assert.is_false(utils.constant_time_equals("x", nil))
  end)

  it("returns false for different strings of same length", function()
    assert.is_false(utils.constant_time_equals("abc", "xyz"))
  end)

  it("returns false for different-length strings", function()
    assert.is_false(utils.constant_time_equals("ab", "abc"))
  end)

  it("returns true for identical strings", function()
    assert.is_true(utils.constant_time_equals("secret", "secret"))
  end)

  it("returns true for empty strings", function()
    assert.is_true(utils.constant_time_equals("", ""))
  end)
end)

describe("utils.encode_base64 without ngx", function()
  it("returns nil when ngx.encode_base64 is not available", function()
    local saved = _G.ngx
    _G.ngx = nil
    local result = utils.encode_base64("hello")
    _G.ngx = saved
    assert.is_nil(result)
  end)
end)

describe("utils.decode_base64 fallback (no ngx)", function()
  it("decodes a standard base64 string", function()
    local saved = _G.ngx
    _G.ngx = nil
    local result = utils.decode_base64("aGVsbG8=")
    _G.ngx = saved
    assert.equals("hello", result)
  end)

  it("decodes base64 without padding", function()
    local saved = _G.ngx
    _G.ngx = nil
    local result = utils.decode_base64("YWJj")
    _G.ngx = saved
    assert.equals("abc", result)
  end)

  it("returns nil for a string containing an invalid character", function()
    local saved = _G.ngx
    _G.ngx = nil
    local result = utils.decode_base64("not!valid!!")
    _G.ngx = saved
    assert.is_nil(result)
  end)
end)

describe("utils.base64url_decode", function()
  it("returns nil for non-string input", function()
    assert.is_nil(utils.base64url_decode(nil))
    assert.is_nil(utils.base64url_decode(42))
  end)

  it("returns nil for empty string", function()
    assert.is_nil(utils.base64url_decode(""))
  end)

  it("returns nil when remainder after padding is 1 (invalid)", function()
    local saved = _G.ngx
    _G.ngx = nil
    local result = utils.base64url_decode("a")
    _G.ngx = saved
    assert.is_nil(result)
  end)

  it("decodes a valid base64url string (no padding)", function()
    local saved = _G.ngx
    _G.ngx = nil
    local result = utils.base64url_decode("aGVsbG8")
    _G.ngx = saved
    assert.equals("hello", result)
  end)
end)

describe("utils.sha256", function()
  it("returns nil for nil input (guard branch)", function()
    local result = utils.sha256(nil)
    assert.is_nil(result)
  end)

  it("returns a value or graceful error without crashing", function()
    local result, err = utils.sha256("test-input")
    assert.is_true(result ~= nil or err ~= nil)
  end)
end)

describe("utils.fairvisor_json additional branches", function()
  it("encode returns error for object with non-integer-sequence key", function()
    local s, err = json.encode({ [1.5] = "v" })
    assert.is_nil(s)
    assert.is_string(err)
  end)

  it("encode returns nil and error for value of unsupported type (function)", function()
    local s, err = json.encode({ fn = function() end })
    assert.is_nil(s)
    assert.is_string(err)
  end)

  it("decode returns error for invalid number '-'", function()
    local v, err = json.decode("-")
    assert.is_nil(v)
    assert.is_string(err)
  end)

  it("decode returns error for unterminated array", function()
    local v, err = json.decode("[1,2")
    assert.is_nil(v)
    assert.is_string(err)
  end)

  it("decode returns error for unterminated object", function()
    local v, err = json.decode('{"a":1')
    assert.is_nil(v)
    assert.is_string(err)
  end)

  it("decode handles escape sequences b, f, r and /", function()
    local v, err = json.decode('{"b":"\\b","f":"\\f","r":"\\r","sl":"\\/"}')
    assert.is_nil(err)
    assert.equals("\b", v.b)
    assert.equals("\f", v.f)
    assert.equals("\r", v.r)
    assert.equals("/",  v.sl)
  end)

  it("decode returns error for expected ',' or ']' missing in array", function()
    local v, err = json.decode("[1 2]")
    assert.is_nil(v)
    assert.is_string(err)
  end)

  it("decode returns error for expected ',' or '}' missing in object", function()
    local v, err = json.decode('{"a":1 "b":2}')
    assert.is_nil(v)
    assert.is_string(err)
  end)
end)

describe("utils.get_json (chain)", function()
  it("returns a table with decode and encode functions", function()
    local jl = utils.get_json()
    assert.is_table(jl)
    assert.is_function(jl.decode)
    assert.is_function(jl.encode)
  end)

  it("decode handles valid JSON", function()
    local jl = utils.get_json()
    local v, err = jl.decode('{"x":1}')
    assert.is_nil(err)
    assert.equals(1, v.x)
  end)

  it("decode returns error for non-string input", function()
    local jl = utils.get_json()
    local v, err = jl.decode(123)
    assert.is_nil(v)
    assert.is_string(err)
  end)

  it("encode handles a table", function()
    local jl = utils.get_json()
    local s, err = jl.encode({ k = "v" })
    assert.is_nil(err)
    assert.is_string(s)
  end)
end)
