#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"

echo "==> Applying Wipeout XL NeGcon patch"
echo "    ROOT: $ROOT"

find_file() {
    find "$ROOT" -type f -name "$1" -not -path '*/.git/*' -print -quit
}

MAIN="$(find_file main.cpp)"
SIO_C="$(find_file sio.c)"
SIO_H="$(find_file sio.h)"

[[ -n "$MAIN" ]] || { echo "ERROR: main.cpp not found"; exit 1; }
[[ -n "$SIO_C" ]] || { echo "ERROR: sio.c not found"; exit 1; }
[[ -n "$SIO_H" ]] || { echo "ERROR: sio.h not found"; exit 1; }

echo "    main.cpp: $MAIN"
echo "    sio.c:    $SIO_C"
echo "    sio.h:    $SIO_H"

# ---------------------------------------------------------------------
# main.cpp
#
# Insertions are applied from bottom to top so the original diff
# line numbers remain valid.
# ---------------------------------------------------------------------

ed -s "$MAIN" <<'EOF'
14916a
        open_negcon(g_players[s], s);
        update_negcon(g_players[s], s);
.
5196a
    /* NeGcon owns the SIO pad state directly. */
    if (sio_get_pad_negcon(s))
        return;
.
5066a
    /* NeGcon uses the raw SDL joystick path, not PlayerInput::kind. */
    if (p.is_negcon && p.negcon_handle) {
        update_negcon(p, s);
        out->buttons = sio_get_pad_buttons_slot(s);
        out->lx = 0x80;
        out->ly = 0x80;
        out->rx = 0x80;
        out->ry = 0x80;
        out->analog = 0;
        out->connected = 1;
        return 1;
    }
.
4437a
        /* NeGcon is a raw SDL joystick, not an SDL GameController. */
        open_negcon(p, s);
.
4356a

static void open_negcon(PlayerInput& p, int self_slot)
{
    if (p.negcon_handle)
        return;

    const int joysticks = SDL_NumJoysticks();

    for (int i = 0; i < joysticks; i++) {
        SDL_JoystickGUID g = SDL_JoystickGetDeviceGUID(i);

        char guid[40] = {0};
        SDL_JoystickGetGUIDString(g, guid, sizeof(guid));

        if (std::strcmp(guid, NEGCON_GUID) != 0)
            continue;

        SDL_JoystickID inst = SDL_JoystickGetDeviceInstanceID(i);

        if (device_claimed_by_other(self_slot, inst))
            continue;

        SDL_Joystick* joy = SDL_JoystickOpen(inst);

        if (!joy)
            continue;

        p.negcon_handle = joy;
        p.is_negcon = true;
        p.instance = inst;

        std::fprintf(stdout,
                     "psxrecomp runtime: opened NeGcon for slot %d\n",
                     self_slot + 1);
        return;
    }
}

static void update_negcon(PlayerInput& p, int slot)
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

    /* NeGcon R = digital bit 11. */
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
}
.
4305a
        if (g_players[o].negcon_handle && g_players[o].instance == inst) return 1;
.
4301a

/* PSXRecomp NeGcon support. */
static constexpr const char* NEGCON_GUID =
    "03004f8eff1100004133000010010000";

static constexpr int NEGCON_TWIST_CENTER = 385;
static constexpr int NEGCON_I_II_CENTER  = 128;
static constexpr int NEGCON_L_CENTER    = 32767;
static constexpr int NEGCON_DEADZONE    = 800;

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

    int v = 128 + ((d - NEGCON_DEADZONE) * 127) /
                   (32767 - NEGCON_TWIST_CENTER - NEGCON_DEADZONE);

    if (v < 128) v = 128;
    if (v > 255) v = 255;
    return (uint8_t)v;
}

static uint8_t negcon_pressure_value(int raw, bool positive)
{
    const int d = raw - NEGCON_I_II_CENTER;

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
.
4294a

    if (p.negcon_handle) {
        SDL_JoystickClose(p.negcon_handle);
        p.negcon_handle = nullptr;
        p.is_negcon = false;
    }
.
371a
    SDL_Joystick* negcon_handle = nullptr;
    bool is_negcon = false;

.
w
EOF

# ---------------------------------------------------------------------
# sio.c
# ---------------------------------------------------------------------

ed -s "$SIO_C" <<'EOF'
1275a
        }
.
1256a
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
                } else {
.
985a

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
.
47a
static uint8_t pad_negcon[PSX_MAX_PLAYERS] = { 0 };
static uint8_t pad_negcon_steering[PSX_MAX_PLAYERS] = { 0x80 };
static uint8_t pad_negcon_i[PSX_MAX_PLAYERS] = { 0 };
static uint8_t pad_negcon_ii[PSX_MAX_PLAYERS] = { 0 };
static uint8_t pad_negcon_l[PSX_MAX_PLAYERS] = { 0 };

.
w
EOF

# ---------------------------------------------------------------------
# sio.h
# ---------------------------------------------------------------------

ed -s "$SIO_H" <<'EOF'
156a
void sio_set_pad_negcon(int slot,
                        uint16_t buttons,
                        uint8_t steering,
                        uint8_t i_value,
                        uint8_t ii_value,
                        uint8_t l_value);
void sio_clear_pad_negcon(int slot);
int sio_get_pad_negcon(int slot);

.
w
EOF

echo
echo "[ok] NeGcon patch inserted"
echo "     main.cpp: $MAIN"
echo "     sio.c:    $SIO_C"
echo "     sio.h:    $SIO_H"

echo "Build:"
echo " cmake --build build-release -j\$(nproc)"
echo
echo "Run:"
echo " ./build-release/wipeoutxl_Recompiled 2>&1 | tee negcon-debug.log"
