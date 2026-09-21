"""Run repository shaders in Mesa GLES; read native 10-bit framebuffer values."""
import ctypes as C
import ctypes.util
import math
import os
from pathlib import Path
import random
import re
import sys

os.environ.setdefault("EGL_PLATFORM", "surfaceless")
os.environ.setdefault("LIBGL_ALWAYS_SOFTWARE", "1")
egl_name = ctypes.util.find_library("EGL")
gles_name = ctypes.util.find_library("GLESv2")
if not egl_name or not gles_name:
    sys.exit(77)
egl, gl = C.CDLL(egl_name), C.CDLL(gles_name)
I, U, F, P = C.c_int, C.c_uint, C.c_float, C.c_void_p


def api(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn


get_display = api(egl, "eglGetDisplay", P, P)
initialize = api(egl, "eglInitialize", U, P, C.POINTER(I), C.POINTER(I))
choose = api(egl, "eglChooseConfig", U, P, C.POINTER(I), C.POINTER(P), I, C.POINTER(I))
create_surface = api(egl, "eglCreatePbufferSurface", P, P, P, C.POINTER(I))
create_context = api(egl, "eglCreateContext", P, P, P, P, C.POINTER(I))
make_current = api(egl, "eglMakeCurrent", U, P, P, P, P)
display = get_display(None)
major, minor = I(), I()
if not initialize(display, C.byref(major), C.byref(minor)):
    sys.exit(77)
assert api(egl, "eglBindAPI", U, U)(0x30A0)
attrs = (I * 13)(0x3033, 1, 0x3040, 0x40, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3038)
config, count = P(), I()
assert choose(display, attrs, C.byref(config), 1, C.byref(count)) and count.value
surface = create_surface(display, config, (I * 5)(0x3057, 2, 0x3056, 1, 0x3038))
context = create_context(display, config, None, (I * 3)(0x3098, 3, 0x3038))
assert surface and context and make_current(display, surface, surface, context)

for name, ret, args in [
    ("glCreateShader", U, [U]), ("glShaderSource", None, [U, I, C.POINTER(C.c_char_p), P]),
    ("glCompileShader", None, [U]), ("glGetShaderiv", None, [U, U, C.POINTER(I)]),
    ("glGetShaderInfoLog", None, [U, I, P, P]), ("glCreateProgram", U, []),
    ("glAttachShader", None, [U, U]), ("glLinkProgram", None, [U]),
    ("glGetProgramiv", None, [U, U, C.POINTER(I)]), ("glGetProgramInfoLog", None, [U, I, P, P]),
    ("glUseProgram", None, [U]), ("glGetUniformLocation", I, [U, C.c_char_p]),
    ("glGetAttribLocation", I, [U, C.c_char_p]), ("glUniform1i", None, [I, I]),
    ("glUniform3i", None, [I, I, I, I]), ("glUniform3f", None, [I, F, F, F]),
    ("glUniformMatrix4fv", None, [I, I, U, P]), ("glGenBuffers", None, [I, C.POINTER(U)]),
    ("glBindBuffer", None, [U, U]), ("glBufferData", None, [U, C.c_ssize_t, P, U]),
    ("glEnableVertexAttribArray", None, [U]), ("glVertexAttribPointer", None, [U, I, U, U, I, P]),
    ("glVertexAttrib2f", None, [U, F, F]), ("glGenTextures", None, [I, C.POINTER(U)]),
    ("glBindTexture", None, [U, U]), ("glTexParameteri", None, [U, U, I]),
    ("glTexImage2D", None, [U, I, I, I, I, I, U, U, P]),
    ("glGenFramebuffers", None, [I, C.POINTER(U)]), ("glBindFramebuffer", None, [U, U]),
    ("glFramebufferTexture2D", None, [U, U, U, U, I]),
    ("glCheckFramebufferStatus", U, [U]), ("glViewport", None, [I, I, I, I]),
    ("glDisable", None, [U]), ("glDrawArrays", None, [U, I, I]),
    ("glReadPixels", None, [I, I, I, I, U, U, P]), ("glGetError", U, []),
    ("glClearColor", None, [F, F, F, F]), ("glClear", None, [U]),
    ("glGetString", C.c_char_p, [U]),
]:
    globals()[name] = api(gl, name, ret, *args)

print("GLES renderer:", glGetString(0x1F01).decode())
glDisable(0x0BD0)  # Dither would hide exact framebuffer code preservation.
glDisable(0x0BE2)
glViewport(0, 0, 2, 1)
fbo, output_tex, input_tex, vbo = U(), U(), U(), U()
glGenFramebuffers(1, C.byref(fbo))
glBindFramebuffer(0x8D40, fbo)
glGenTextures(1, C.byref(output_tex))
glGenTextures(1, C.byref(input_tex))
glGenBuffers(1, C.byref(vbo))
vertices = (F * 8)(-1, -1, 1, -1, -1, 1, 1, 1)
glBindBuffer(0x8892, vbo)
glBufferData(0x8892, C.sizeof(vertices), vertices, 0x88E4)


def target(ten_bit):
    glBindTexture(0x0DE1, output_tex)
    glTexImage2D(0x0DE1, 0, 0x8059 if ten_bit else 0x8058, 2, 1, 0, 0x1908,
                 0x8368 if ten_bit else 0x1401, None)
    glFramebufferTexture2D(0x8D40, 0x8CE0, 0x0DE1, output_tex, 0)
    assert glCheckFramebufferStatus(0x8D40) == 0x8CD5
    glBindTexture(0x0DE1, input_tex)
    glTexParameteri(0x0DE1, 0x2801, 0x2600)
    glTexParameteri(0x0DE1, 0x2800, 0x2600)
    glTexImage2D(0x0DE1, 0, 0x8058, 1, 1, 0, 0x1908, 0x1401,
                 (C.c_ubyte * 4)(73, 46, 99, 255))


def shader(kind, source):
    handle = glCreateShader(kind)
    text = C.c_char_p(source.encode())
    glShaderSource(handle, 1, C.byref(text), None)
    glCompileShader(handle)
    ok, log = I(), C.create_string_buffer(8192)
    glGetShaderiv(handle, 0x8B81, C.byref(ok))
    glGetShaderInfoLog(handle, len(log), None, log)
    assert ok.value, log.value.decode()
    return handle


def program(path, method):
    source = path.read_text().split("void ofxRPI4Window::" + method + "()", 1)[1]
    blocks = re.findall(r'settings.shaderSources\[GL_(VERTEX|FRAGMENT)_SHADER\]\s*=\s*R"\((.*?)\)";', source, re.S)[:2]
    assert len(blocks) == 2
    result = glCreateProgram()
    for kind, text in blocks:
        glAttachShader(result, shader(0x8B31 if kind == "VERTEX" else 0x8B30, text))
    glLinkProgram(result)
    ok, log = I(), C.create_string_buffer(8192)
    glGetProgramiv(result, 0x8B82, C.byref(ok))
    glGetProgramInfoLog(result, len(log), None, log)
    assert ok.value, log.value.decode()
    glUseProgram(result)
    position = glGetAttribLocation(result, b"position")
    glEnableVertexAttribArray(position)
    glVertexAttribPointer(position, 2, 0x1406, 0, 0, None)
    uv = glGetAttribLocation(result, b"texcoord")
    if uv >= 0:
        glVertexAttrib2f(uv, 0.5, 0.5)
    matrix = (F * 16)(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1)
    glUniformMatrix4fv(glGetUniformLocation(result, b"modelViewProjectionMatrix"), 1, 0, matrix)
    return result


def uniform(name, *values, floating=False):
    location = glGetUniformLocation(current_program, name.encode())
    if len(values) == 1:
        glUniform1i(location, values[0])
    elif floating:
        glUniform3f(location, *values)
    else:
        glUniform3i(location, *values)


def read(ten_bit=True, draw=True):
    if draw:
        glDrawArrays(0x0005, 0, 4)
    pixels = (U * 2)() if ten_bit else (C.c_ubyte * 8)()
    glReadPixels(0, 0, 2, 1, 0x1908, 0x8368 if ten_bit else 0x1401, pixels)
    assert glGetError() == 0
    if ten_bit:
        return [(p & 1023, (p >> 10) & 1023, (p >> 20) & 1023) for p in pixels]
    return [tuple(pixels[i:i + 3]) for i in (0, 4)]


def yuv(rgb, bt2020, limited, bits):
    # Independent BT matrix reference, computed from luma weights.
    kr, kb = (0.2627, 0.0593) if bt2020 else (0.2126, 0.0722)
    y = kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2]
    ratio = 224 / 219 if limited else 256 / 255
    cb = (rgb[2] - y) / (2 * (1 - kb)) * ratio + (128 << (bits - 8))
    cr = (rgb[0] - y) / (2 * (1 - kr)) * ratio + (128 << (bits - 8))
    return tuple(math.floor(v + 0.5) for v in (y, cb, cr))


root = Path(__file__).resolve().parents[2]
checks = 0
for backend in ("ofxRPI4Window", "ofxRPI4Window-pi5"):
    path = root / "src" / backend / "src/ofxRPI4Window.cpp"
    current_program = program(path, "rgb2ycbcr_shader")
    for name in ("source_codes", "source_normalizer", "is_image"):
        assert glGetUniformLocation(current_program, name.encode()) >= 0
    for bits in (8, 10):
        target(bits == 10)
        maximum = (1 << bits) - 1
        for name in ("source_normalizer", "normalizer", "scale"):
            uniform(name, maximum)
        for bt2020 in (False, True):
            uniform("coeffs_num", *( (0.2627, 0.6780, 0.0593) if bt2020 else (0.2126, 0.7152, 0.0722)), floating=True)
            uniform("coeffs_div", *( (1.8814, 1.4746, 0.5) if bt2020 else (1.8556, 1.5748, 0.5)), floating=True)
            for limited in (False, True):
                uniform("scalar1", (224 if limited else 256) << (bits - 8))
                uniform("scalar2", (219 if limited else 255) << (bits - 8))
                uniform("offset", 128 << (bits - 8))
                uniform("is_image", 0)
                uniform("passthrough_422", 0)
                for fmt in (0, 1, 2):
                    uniform("color_format", fmt)
                    for code in range(maximum + 1):
                        uniform("source_codes", code, code, code)
                        mid = 128 << (bits - 8)
                        expected = (code, code, code) if fmt == 0 else ((mid, mid, code) if fmt == 1 else (code, mid, mid))
                        assert read(bits == 10) == [expected, expected], (backend, bits, fmt, code)
                        checks += 1
                    rng = random.Random(230)
                    colours = [(maximum, 0, 0), (0, maximum, 0), (0, 0, maximum)]
                    colours += [tuple(rng.randrange(maximum + 1) for _ in range(3)) for _ in range(32)]
                    for rgb in colours:
                        uniform("source_codes", *rgb)
                        y, cb, cr = yuv(rgb, bt2020, limited, bits)
                        expected = rgb if fmt == 0 else ((cb, cr, y) if fmt == 1 else (y, cb, cr))
                        expected = tuple(max(0, min(maximum, v)) for v in expected)
                        actual = read(bits == 10)[0]
                        # Non-neutral float matrix arithmetic may land either side
                        # of a half-code tie. Neutral codes above must be exact.
                        assert all(abs(a - b) <= (0 if fmt == 0 else 1) for a, b in zip(actual, expected)), (backend, rgb, actual, expected)
                        checks += 1
                uniform("color_format", 2)
                uniform("passthrough_422", 1)
                uniform("source_codes", 1, maximum // 2, maximum - 1)
                assert read(bits == 10)[0] == (1, maximum // 2, maximum - 1)
        # Texture sampling is not replaced by source_codes.
        uniform("color_format", 0)
        uniform("is_image", 1)
        expected = tuple(math.floor(v * maximum / 255 + 0.5) for v in (73, 46, 99))
        actual = read(bits == 10)[0]
        # Keep the existing sampler precision; texture conversion may differ
        # by one output code. Solid integer inputs above have zero tolerance.
        assert all(abs(a-b) <= 1 for a, b in zip(actual, expected)), (backend, bits, "image", actual, expected)
        for code in range(maximum + 1):
            value = C.c_float(C.c_float(code / maximum).value * 255).value / 255
            glClearColor(value, value, value, 1)
            glClear(0x4000)
            assert read(bits == 10, draw=False)[0] == (code, code, code)
            checks += 1
    current_program = program(path, "dovi_pattern_shader")
    target(False)  # Standard DV deliberately packs 12-bit values into bytes.
    for name in ("source_rgb", "source_max"):
        assert glGetUniformLocation(current_program, name.encode()) >= 0
    uniform("coeffs_num", 0.2126, 0.7152, 0.0722, floating=True)
    uniform("coeffs_div", 1.8556, 1.5748, 0.5, floating=True)
    for maximum, shift in ((255, 4), (1023, 2), (4095, 0)):
        uniform("source_max", maximum)
        for code in (0, 1, 16, 64, 81, 82, 84, 85, maximum // 2, maximum):
            uniform("source_rgb", code, code, code, floating=True)
            y = code << shift
            expected = (128, y >> 4, y & 15)
            assert read(False) == [expected, expected], (backend, maximum, code, read(False), expected)
            checks += 1
        for bt2020 in (False, True):
            uniform("coeffs_num", *((0.2627, 0.6780, 0.0593) if bt2020 else (0.2126, 0.7152, 0.0722)), floating=True)
            uniform("coeffs_div", *((1.8814, 1.4746, 0.5) if bt2020 else (1.8556, 1.5748, 0.5)), floating=True)
            for rgb in ((maximum, 0, 0), (0, maximum, 0), (0, 0, maximum), (81, 84, 85)):
                uniform("source_rgb", *rgb, floating=True)
                first, second = read(False)
                decoded = (first[1]*16 + (first[2] & 15), first[0]*16 + (first[2] >> 4),
                           second[0]*16 + (second[2] >> 4))
                expected = tuple(max(0, min(4095, v)) for v in yuv(tuple(v << shift for v in rgb), bt2020, True, 12))
                assert all(abs(a-b) <= 1 for a, b in zip(decoded, expected)), (backend, "DV", rgb, decoded, expected)
                assert abs(second[1]*16 + (second[2] & 15) - decoded[0]) <= 1
                checks += 1
    print(backend, "shader precision and DV input checks passed")
print("Passed", checks, "framebuffer checks; these are not HDMI wire captures")
