/* pin-unlock@dome.local — log in as soon as the PIN is fully typed.
 *
 * WHAT THIS IS NOT: it does not check the password after every character.
 * That is impossible here, not merely slow, and the shell's own source says so
 * (gdm/authPrompt.js in gnome-shell 46):
 *
 *   - every check is a full PAM conversation, and pam_unix on this machine has
 *     no `nodelay`, so a wrong answer costs a ~2 s delay before the next one;
 *   - _onVerificationFailed() calls this.clear(), which does _entry.set_text('')
 *     — the box is WIPED after every wrong answer, so a per-character check
 *     would erase character 1 before character 2 could be typed;
 *   - _activateNext() calls updateSensitivity(false), which drops the entry's
 *     `reactive` and moves key focus away until the answer comes back, so the
 *     keystrokes in between would go nowhere anyway.
 *
 * Windows Hello does not do it either. A Hello PIN is a fixed-length credential
 * and Windows submits when the entered length equals the stored length — which
 * is exactly what this does, at the length in the `pin-length` file.
 *
 * HOW IT HOOKS IN. authPrompt.js wires the entry up like this:
 *
 *   entry.clutter_text.connect('activate', () => { ... this._activateNext() });
 *
 * so emitting `activate` on that ClutterText IS pressing Enter — a public
 * signal on a public widget. Nothing here touches AuthPrompt's private fields.
 * The entry is found through global.stage's key focus rather than by importing
 * the dialog, so the same code covers the greeter and the lock screen and a
 * future shell that rearranges either one just quietly stops matching.
 *
 * SAFETY. A pin-length that does not match the real password would otherwise be
 * unrecoverable: every attempt would be submitted N characters in, cleared, and
 * retyped, forever, with no way to type the rest. MAX_AUTO_SUBMITS disarms the
 * whole thing after a few tries so the prompt falls back to plain "type it and
 * press Enter". The counter resets in enable(), and enable() runs on every entry
 * into gdm/unlock-dialog mode — so a successful unlock always rearms it.
 */

import Clutter from 'gi://Clutter';
import GLib from 'gi://GLib';
import St from 'gi://St';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

// The only two session modes that ask for the login password. metadata.json
// already limits the extension to these, so it is not even loaded while the
// session is in normal use; this is the belt to that pair of braces, and it is
// what keeps a polkit prompt on the greeter from being auto-submitted.
const AUTH_MODES = ['gdm', 'unlock-dialog'];

// Give up auto-submitting after this many tries per prompt — see SAFETY above.
const MAX_AUTO_SUBMITS = 3;

// Same range system/87-login-pin.sh enforces on loginPinLength, repeated here
// because pin-length is a plain file somebody can edit by hand.
const MIN_PIN_LENGTH = 4;
const MAX_PIN_LENGTH = 64;

export default class PinUnlockExtension extends Extension {
    enable() {
        this._focusId = 0;
        this._textChangedId = 0;
        this._idleId = 0;
        this._text = null;
        this._submits = 0;
        this._pinLength = this._readPinLength();

        // No usable length configured: stay completely inert rather than guess.
        if (this._pinLength === 0)
            return;

        this._focusId = global.stage.connect('notify::key-focus',
            () => this._onKeyFocusChanged());
        this._onKeyFocusChanged();
    }

    disable() {
        if (this._focusId) {
            global.stage.disconnect(this._focusId);
            this._focusId = 0;
        }
        if (this._idleId) {
            GLib.source_remove(this._idleId);
            this._idleId = 0;
        }
        this._untrack();
        this._pinLength = 0;
    }

    /* The length lives in a file next to this one rather than in GSettings: it
     * is set from loginPinLength in user-config.nix and re-asserted by
     * `sudo make system`, and one file readable by both the gdm user and the
     * logged-in user is less to keep in sync than the same key written into two
     * separate dconf databases. Anything unreadable or out of range disables
     * the extension instead of falling back to a guessed length. */
    _readPinLength() {
        const path = GLib.build_filenamev([this.path, 'pin-length']);
        let raw;

        try {
            const [ok, bytes] = GLib.file_get_contents(path);
            if (!ok)
                return 0;
            raw = new TextDecoder().decode(bytes).trim();
        } catch (e) {
            return 0;
        }

        const length = Number.parseInt(raw, 10);
        if (!Number.isInteger(length) ||
            length < MIN_PIN_LENGTH || length > MAX_PIN_LENGTH) {
            console.warn(`pin-unlock: ignoring unusable pin-length ${JSON.stringify(raw)}`);
            return 0;
        }

        return length;
    }

    _onKeyFocusChanged() {
        this._untrack();

        if (!AUTH_MODES.includes(Main.sessionMode.currentMode))
            return;

        const focus = global.stage.key_focus;
        if (!(focus instanceof Clutter.Text))
            return;

        // St.PasswordEntry only. The username prompt is a plain St.Entry and
        // must never be submitted early — authPrompt.js swaps the two in
        // _updateEntry(), and each swap re-grabs focus and re-runs this.
        if (!(focus.get_parent() instanceof St.PasswordEntry))
            return;

        this._text = focus;
        this._textChangedId =
            this._text.connect('text-changed', () => this._onTextChanged());
    }

    _untrack() {
        if (this._textChangedId) {
            this._text.disconnect(this._textChangedId);
            this._textChangedId = 0;
        }
        this._text = null;
    }

    _onTextChanged() {
        if (this._idleId || this._submits >= MAX_AUTO_SUBMITS)
            return;
        if (this._text.get_text().length !== this._pinLength)
            return;

        // Never activate from inside text-changed: _activateNext() drops the
        // entry's reactive flag and moves key focus, i.e. it mutates the actor
        // that is still emitting this signal. An idle callback lets the current
        // emission finish first.
        this._idleId = GLib.idle_add(GLib.PRIORITY_DEFAULT_IDLE, () => {
            this._idleId = 0;
            this._submit();
            return GLib.SOURCE_REMOVE;
        });
    }

    _submit() {
        const text = this._text;
        if (!text || text.get_text().length !== this._pinLength)
            return;

        // authPrompt.js guards its own activate handler with `if (entry.reactive)`
        // and clears reactive while an answer is in flight. Honouring the same
        // gate is what stops a second attempt being queued behind the first.
        const entry = text.get_parent();
        if (!entry || !entry.reactive)
            return;

        this._submits++;
        if (this._submits === MAX_AUTO_SUBMITS) {
            console.warn('pin-unlock: giving up after ' +
                `${MAX_AUTO_SUBMITS} attempts — is loginPinLength right? ` +
                'Type the password and press Enter.');
        }

        text.activate();
    }
}
