python3 - <<'PY'
from pathlib import Path
from datetime import datetime
import re
import shutil
import sys

ROOT = Path("/media/rt/727e1ded-f524-48dd-a9e0-f88e2526d7e61/pcport/woxl2/wipeoutxlRecomp")
MAIN = ROOT / "psxrecomp/runtime/src/main.cpp"
SIO_C = ROOT / "psxrecomp/runtime/src/sio.c"
SIO_H = ROOT / "psxrecomp/runtime/include/sio.h"

if not ROOT.is_dir():
    sys.exit(f"Project not found: {ROOT}")

for p in (MAIN, SIO_C, SIO_H):
    if not p.exists():
        sys.exit(f"Missing file: {p}")

stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
for p in (MAIN, SIO_C, SIO_H):
    shutil.copy2(p, p.with_name(p.name + f".negcon-backup-{stamp}"))

def replace_once(path, old, new, label):
    s = path.read_text()
    if new in s:
        print(f"[ok] already present: {label}")
        return s
    if old not in s:
        raise RuntimeError(f"Could not find patch target: {label}\n  file: {path}")
    s = s.replace(old, new, 1)
    path.write_text(s)
    print(f"[+] patched: {label}")
    return s

# ----------------------------------------------------------------------
# main.cpp
# ----------------------------------------------------------------------

s = MAIN.read_text()

# Remove temporary B diagnostic, if present.
s = re.sub(
    r'\n\s*static int last_negcon_b = -1;\n'
    r'\s*const int negcon_b = SDL_GetJoystickButton\(joy, 0\);\n'
    r'\s*if \(negcon_b != last_negcon_b\) \{\n'
    r'\s*fprintf\(stderr, "\[NeGcon\] SDL B=%d\\\\n", negcon_b\);\n'
    r'\s*last_negcon_b = negcon_b;\n'
    r'\s*\}\n',
    '\n',
    s,
)

# Constants.
if "NEGCON_GUID" not in s:
    marker = "#include"
    # Put constants immediately before the first static controller block.
    m = re.search(r'\nstatic constexpr', s)
    if not m:
        raise RuntimeError("Could not find insertion point for NeGcon constants")
    block = r'''
/* PSXRecomp NeGcon support. */
static constexpr const char* NEGCON_GUID =
    "03004f8eff1100004133000010010000";

static constexpr int NEGCON_TWIST_CENTER = 385;
static constexpr int NEGCON_I_II_CENTER  = 128;
static constexpr int NEGCON_L_CENTER     = 32767;
static constexpr int NEGCON_DEADZONE    = 800;

'''
    s = s[:m.start()+1] + block + s[m.start()+1:]
    print("[+] added: NeGcon constants")
else:
    print("[ok] already present: NeGcon constants")

# Conversion helpers.
if "static uint8_t negcon_steering_value" not in s:
    marker = "static void update_negcon"
    pos = s.find(marker)
    if pos < 0:
        raise RuntimeError("Could not find update_negcon()")
    helpers = r'''
static uint8_t negcon_steering_value(int raw)
{
    const int d = raw - NEGCON_TWIST_CENTER;

    if (d > -NEGCON_DEADZONE && d < NEGCON_DEADZONE)
        return 0x80;

    if (d < 0) {
        int v = 128 + ((d + NEGCON_DEADZONE) * 128) /
                       (32768 + NEGCON_TWIST_CENTER - NEGCON_DEADZONE);
        if (v < 0) v = 0;
        if (v > 127) v = 127;
        return (uint8_t)v;
    }

    /* NeGcon: 0x00 = right, 0x80 = center, 0xFF = left. */
    int v = 128 + ((d - NEGCON_DEADZONE) * 127) /
                   (32767 - NEGCON_TWIST_CENTER - NEGCON_DEADZONE);
    if (v < 128) v = 128;
    if (v > 255) v = 255;
    return (uint8_t)v;
}

static uint8_t negcon_pressure_value(int raw, bool positive)
{
    int d = raw - NEGCON_I_II_CENTER;

    if (d > -NEGCON_DEADZONE && d < NEGCON_DEADZONE)
        return 0;

    if (positive) {
        if (d <= NEGCON_DEADZONE)
            return 0;

        int v = ((d - NEGCON_DEADZONE) * 255) /
                (32767 - NEGCON_I_II_CENTER - NEGCON_DEADZONE);

        if (v < 0) v = 0;
        if (v > 255) v = 255;
        return (uint8_t)v;
    }

    if (d >= -NEGCON_DEADZONE)
        return 0;

    int v = ((-d - NEGCON_DEADZONE) * 255) /
            (32768 + NEGCON_I_II_CENTER - NEGCON_DEADZONE);

    if (v < 0) v = 0;
    if (v > 255) v = 255;
    return (uint8_t)v;
}

static uint8_t negcon_l_value(int raw)
{
    const int d = NEGCON_L_CENTER - raw;

    if (d <= NEGCON_DEADZONE)
        return 0;

    int v = ((d - NEGCON_DEADZONE) * 255) /
            (32767 - NEGCON_DEADZONE);

    if (v < 0) v = 0;
    if (v > 255) v = 255;
    return (uint8_t)v;
}

'''
    s = s[:pos] + helpers + s[pos:]
    print("[+] added: NeGcon analog conversion helpers")
else:
    print("[ok] already present: NeGcon analog conversion helpers")

# Replace/update update_negcon body.
start = s.find("static void update_negcon")
if start < 0:
    raise RuntimeError("update_negcon() not found")

brace = s.find("{", start)
depth = 0
end = None
for i in range(brace, len(s)):
    if s[i] == "{":
        depth += 1
    elif s[i] == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break

if end is None:
    raise RuntimeError("Could not parse update_negcon()")

update = r'''static void update_negcon(PlayerInput& p, int slot)
{
    if (!p.negcon_handle)
        return;

    SDL_UpdateJoysticks();

    SDL_Joystick* joy = p.negcon_handle;

    const int twist = SDL_GetJoystickAxis(joy, 0);
    const int i_ii  = SDL_GetJoystickAxis(joy, 1);
    const int l_raw = SDL_GetJoystickAxis(joy, 2);

    uint16_t buttons = 0xFFFF;

    const Uint8 hat = SDL_GetJoystickHat(joy, 0);

    if (hat & SDL_HAT_UP)
        buttons &= (uint16_t)~0x0010;
    if (hat & SDL_HAT_RIGHT)
        buttons &= (uint16_t)~0x0020;
    if (hat & SDL_HAT_DOWN)
        buttons &= (uint16_t)~0x0040;
    if (hat & SDL_HAT_LEFT)
        buttons &= (uint16_t)~0x0080;

    /* NeGcon A. */
    if (SDL_GetJoystickButton(joy, 1))
        buttons &= (uint16_t)~0x1000;

    /* NeGcon B. */
    if (SDL_GetJoystickButton(joy, 0))
        buttons &= (uint16_t)~0x4000;

    /* NeGcon II. */
    if (negcon_pressure_value(i_ii, true) != 0)
        buttons &= (uint16_t)~0x2000;

    /* NeGcon R is digital bit 11. */
    if (SDL_GetJoystickButton(joy, 7))
        buttons &= (uint16_t)~0x0800;

    /* NeGcon START. */
    if (SDL_GetJoystickButton(joy, 9))
        buttons &= (uint16_t)~0x0008;

    sio_set_pad_connected(slot, 1);
    sio_set_pad_config_capable(slot, 0);

    sio_set_pad_negcon(
        slot,
        buttons,
        negcon_steering_value(twist),
        negcon_pressure_value(i_ii, false),
        negcon_pressure_value(i_ii, true),
        negcon_l_value(l_raw));
}'''

s = s[:start] + update + s[end:]
MAIN.write_text(s)
print("[+] patched: update_negcon()")

# ----------------------------------------------------------------------
# sio.h
# ----------------------------------------------------------------------

s = SIO_H.read_text()

if "void sio_set_pad_negcon(" not in s:
    marker = "void sio_set_pad_connected"
    pos = s.find(marker)
    if pos < 0:
        raise RuntimeError("Could not find SIO pad API insertion point")

    api = r'''void sio_set_pad_negcon(int slot,
                        uint16_t buttons,
                        uint8_t steering,
                        uint8_t i_value,
                        uint8_t ii_value,
                        uint8_t l_value);
void sio_clear_pad_negcon(int slot);
int sio_get_pad_negcon(int slot);

'''
    s = s[:pos] + api + s[pos:]
    SIO_H.write_text(s)
    print("[+] patched: sio.h NeGcon API")
else:
    print("[ok] already present: sio.h NeGcon API")

# ----------------------------------------------------------------------
# sio.c
# ----------------------------------------------------------------------

s = SIO_C.read_text()

# State arrays.
if "pad_negcon_steering" not in s:
    marker = "static uint16_t pad_buttons"
    pos = s.find(marker)
    if pos < 0:
        raise RuntimeError("Could not find pad state insertion point")

    state = r'''static uint8_t pad_negcon[PSX_MAX_PLAYERS] = { 0 };
static uint8_t pad_negcon_steering[PSX_MAX_PLAYERS] = { 0x80 };
static uint8_t pad_negcon_i[PSX_MAX_PLAYERS] = { 0 };
static uint8_t pad_negcon_ii[PSX_MAX_PLAYERS] = { 0 };
static uint8_t pad_negcon_l[PSX_MAX_PLAYERS] = { 0 };

'''
    s = s[:pos] + state + s[pos:]
    print("[+] added: SIO NeGcon state arrays")
else:
    print("[ok] already present: SIO NeGcon state arrays")

# API implementation.
if "void sio_set_pad_negcon(" not in s:
    # Put after the normal pad connection/config setters.
    matches = list(re.finditer(r'\n(?:void|int)\s+sio_set_pad_[^(]+\(', s))
    if not matches:
        raise RuntimeError("Could not find SIO setter insertion point")

    pos = matches[-1].start()

    api_impl = r'''
void sio_set_pad_negcon(int slot,
                        uint16_t buttons,
                        uint8_t steering,
                        uint8_t i_value,
                        uint8_t ii_value,
                        uint8_t l_value)
{
    if (slot < 0 || slot >= PSX_MAX_PLAYERS)
        return;

    pad_buttons[slot] = buttons;
    pad_negcon[slot] = 1;
    pad_negcon_steering[slot] = steering;
    pad_negcon_i[slot] = i_value;
    pad_negcon_ii[slot] = ii_value;
    pad_negcon_l[slot] = l_value;
    pad_analog[slot] = 0;
    pad_type_req[slot] = -1;
}

void sio_clear_pad_negcon(int slot)
{
    if (slot < 0 || slot >= PSX_MAX_PLAYERS)
        return;

    pad_negcon[slot] = 0;
    pad_negcon_steering[slot] = 0x80;
    pad_negcon_i[slot] = 0;
    pad_negcon_ii[slot] = 0;
    pad_negcon_l[slot] = 0;
}

int sio_get_pad_negcon(int slot)
{
    if (slot < 0 || slot >= PSX_MAX_PLAYERS)
        return 0;

    return pad_negcon[slot] != 0;
}

'''
    s = s[:pos] + api_impl + s[pos:]
    print("[+] added: SIO NeGcon API")

# NeGcon 0x42 response.
if "pad_response[0] = 0x23" not in s:
    old = '''if (tx_byte == 0x42) {
                '''
    # Find the actual tx_byte == 0x42 block and insert NeGcon branch
    # immediately after its opening brace.
    m = re.search(r'if\s*\(tx_byte\s*==\s*0x42\)\s*\{', s)
    if not m:
        raise RuntimeError("Could not find SIO 0x42 pad transaction")

    insert = r'''
                if (pad_negcon[lp]) {
                    const uint16_t btn = pad_buttons[lp];

                    pad_response[0] = 0x23;
                    pad_response[1] = 0x5A;
                    pad_response[2] = (uint8_t)(btn & 0xFF);
                    pad_response[3] = (uint8_t)(btn >> 8);
                    pad_response[4] = pad_negcon_steering[lp];
                    pad_response[5] = pad_negcon_i[lp];
                    pad_response[6] = pad_negcon_ii[lp];
                    pad_response[7] = pad_negcon_l[lp];

                    pad_response_len = 8;
                    pad_state = PAD_SEND_RESPONSE;
                    sio_rx_data = pad_response[0];
                    sio_stat |= SIO_STAT_ACK;
                } else '''
    brace_end = m.end()
    s = s[:brace_end] + insert + s[brace_end:]
    print("[+] added: SIO NeGcon 0x42 response")

# Disconnect/reset handling.
if "pad_negcon[slot] = 0;" not in s:
    print("[warn] could not automatically add NeGcon disconnect reset")

SIO_C.write_text(s)

# ----------------------------------------------------------------------
# Duplicate device claim protection in main.cpp
# ----------------------------------------------------------------------

s = MAIN.read_text()

old = '''        if (g_players[o].handle && g_players[o].instance == inst)
            return 1;
'''
new = '''        if (g_players[o].handle && g_players[o].instance == inst)
            return 1;

        if (g_players[o].negcon_handle && g_players[o].instance == inst)
            return 1;
'''

if new not in s and old in s:
    s = s.replace(old, new, 1)
    MAIN.write_text(s)
    print("[+] patched: duplicate NeGcon claim protection")
elif new in s:
    print("[ok] already present: duplicate NeGcon claim protection")
else:
    print("[warn] duplicate-claim block not found")

print()
print("NeGcon patch complete.")
print(f"Backups: *.negcon-backup-{stamp}")
print()
print("Build with:")
print("  cd /media/rt/727e1ded-f524-48dd-a9e0-f88e2526d7e61/pcport/woxl2/wipeoutxlRecomp")
print("  cmake --build build-release -j$(nproc)")
PY
