#!/usr/bin/env python3
"""Seed Xournal++'s appearance settings — the half of the app GTK cannot dress.

Xournal++ is themed in two independent places, and only one of them is the
desktop's business:

  window chrome   GTK3, so Yaru-dark already applies. Verified by tracing the
                  running app: it opens /usr/share/themes/Yaru-dark/gtk-3.0/
                  gtk.css. Nothing here touches it, and forcing a per-app
                  GTK_THEME would only make it clash with every other window.
  canvas + icons  Xournal++'s own, read from ~/.config/xournalpp/settings.xml.
                  Its defaults are the 2008 ones: a multi-colour icon set, a
                  light-grey canvas surround under a dark desktop, a pure-green
                  pen and a pure-yellow highlighter. That is what this seeds.

SEED, NOT PIN — the same contract as the dark-mode seed in home.nix. Xournal++
REWRITES settings.xml in full every time it exits, so a home-manager symlink
would either be clobbered or make the app unable to save its own preferences.
Instead this runs once, drops a marker beside the settings file, and never
touches it again; change anything in Preferences afterwards and it stands.
Delete the marker and re-run `make home` to get dome's look back.

Only the named keys are rewritten. Everything else in the file — window size,
recent paths, device classes, button mappings — is preserved as-is.
"""

import os
import sys
import xml.etree.ElementTree as ET

# Notion's own colours, light mode. See modules/xournalpp.nix for where the
# palette these draw from comes from and why these specific values.
NOTION_INK = "37352f"        # Notion's default text colour, a warm near-black
NOTION_BLUE = "337ea9"
NOTION_GREEN = "448361"
NOTION_RED = "d44c47"
HIGHLIGHT_YELLOW = "e2c28d"  # the lifted yellow from the palette

# The canvas surround. Notion's dark page is #191919; this is a shade up so the
# white page keeps a visible edge against it rather than floating in black.
CANVAS = "1f1f1f"


def argb(rgb: str) -> str:
    """'337ea9' -> the opaque-ARGB decimal Xournal++ stores in settings.xml."""
    return str(0xFF000000 | int(rgb, 16))


def properties(palette_path: str) -> "dict[str, str]":
    return {
        # The modern icon set. Ships in the same package as the default
        # `iconsColor`, in both a dark and a light variant, and Xournal++ picks
        # the variant to match the GTK theme on its own.
        "iconTheme": "iconsLucide",
        "colorPalette": palette_path,
        "backgroundColor": argb(CANVAS),
        # Pure red for a selection box, lawn green for an active one. Both are
        # legible, neither belongs next to anything else on this desktop.
        "selectionBorderColor": argb(NOTION_BLUE),
        "selectionMarkerColor": argb(NOTION_BLUE),
        "activeSelectionColor": argb(NOTION_GREEN),
        # The stroke stabiliser, off by default in a shipped Xournal++ and the
        # single biggest difference to how handwriting LOOKS. The numeric
        # parameters it reads (buffer 20, sigma 0.5, deadzone radius 1.3) are
        # already at their defaults in a fresh settings.xml, so turning the two
        # methods on is the whole change:
        #   averaging method  2 = velocity gaussian — smooths fast strokes hard
        #                         and slow ones barely, so detail survives
        #   preprocessor      1 = deadzone — drops the sub-pixel tremor a
        #                         stylus emits while the nib is resting
        "stabilizerAveragingMethod": "2",
        "stabilizerPreprocessor": "1",
    }


# Per-tool default colours, as the hex-with-alpha attribute the tools block
# uses. These are what the toolbar comes up with; the palette above is what the
# colour picker then offers.
TOOL_COLORS = {
    "pen": "ff" + NOTION_INK,
    "text": "ff" + NOTION_INK,
    "highlighter": "ff" + HIGHLIGHT_YELLOW,
    "laserPointerPen": "ff" + NOTION_RED,
    "laserPointerHighlighter": "ff" + NOTION_RED,
}

# The text tool's font. Left at "Sans 12" a shipped Xournal++ renders typed
# annotations in whatever fontconfig calls Sans, at a size nothing else on the
# desktop uses.
FONT_NAME = "Ubuntu Sans"
FONT_SIZE = "11"


def set_property(root, name: str, value: str) -> None:
    el = root.find(f"./property[@name='{name}']")
    if el is None:
        el = ET.SubElement(root, "property")
        el.set("name", name)
    el.set("value", value)


def set_tool_color(root, tool: str, color: str) -> None:
    """Set one tool's default colour, creating the nodes if the file predates it."""
    tools = root.find("./data[@name='tools']")
    if tools is None:
        tools = ET.SubElement(root, "data")
        tools.set("name", "tools")
    node = tools.find(f"./data[@name='{tool}']")
    if node is None:
        node = ET.SubElement(tools, "data")
        node.set("name", tool)
    attr = node.find("./attribute[@name='color']")
    if attr is None:
        attr = ET.SubElement(node, "attribute")
        attr.set("name", "color")
        attr.set("type", "hex")
    attr.set("value", color)


def set_font(root) -> None:
    el = root.find("./property[@name='font']")
    if el is None:
        el = ET.SubElement(root, "property")
        el.set("name", "font")
    # This one property is spelled with its own attributes rather than a value.
    el.set("font", FONT_NAME)
    el.set("size", FONT_SIZE)


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: xournalpp-appearance.py <settings.xml> <palette.gpl>", file=sys.stderr)
        return 2
    settings_path, palette_path = sys.argv[1], sys.argv[2]

    if os.path.exists(settings_path):
        try:
            tree = ET.parse(settings_path)
        except ET.ParseError as exc:
            print(f"[xournalpp] settings.xml is not parseable ({exc}) — left alone", file=sys.stderr)
            return 1
        root = tree.getroot()
    else:
        # No settings file yet, because the app has never been run. A partial
        # one is fine: Xournal++ fills in its defaults for every key it does not
        # find, then writes the complete file back on first exit.
        root = ET.Element("settings")
        tree = ET.ElementTree(root)
        os.makedirs(os.path.dirname(settings_path), exist_ok=True)

    for name, value in properties(palette_path).items():
        set_property(root, name, value)
    for tool, color in TOOL_COLORS.items():
        set_tool_color(root, tool, color)
    set_font(root)

    # The button-config pen carries its own colour, separate from the tools
    # block, and it is what a stylus button press draws with.
    button = root.find("./data[@name='buttonConfig']/data[@name='default']/attribute[@name='color']")
    if button is not None:
        button.set("value", "ff" + NOTION_INK)

    ET.indent(tree, space="  ")
    # ElementTree drops the explanatory comments Xournal++ puts above several
    # keys ("allowed values are ..."). That is self-healing rather than a loss:
    # measured by closing the app through a real window close, it rewrites the
    # whole file on quit and restores all twelve of them, with every value
    # seeded here preserved. A SIGTERM does NOT save, so a killed instance
    # simply leaves this file as written.
    #
    # Writing to a temp file first means a crash here cannot leave a
    # half-written settings.xml behind.
    tmp = settings_path + ".dome-tmp"
    tree.write(tmp, encoding="UTF-8", xml_declaration=True)
    os.replace(tmp, settings_path)
    print("[xournalpp] appearance seeded: Lucide icons, Notion palette, dark canvas, stabiliser on")
    return 0


if __name__ == "__main__":
    sys.exit(main())
