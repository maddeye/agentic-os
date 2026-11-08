#!/usr/bin/python3
# A real GTK application that reports what it receives. It paints red until the left
# button goes down, then green. With --animate a bar moves, and with --animate-full a
# gradient changes every pixel, so recordings have small or full-frame motion.
import sys

import cairo
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

color = (1.0, 0.0, 0.0)
offset = 0
GLib.set_prgname("agentostest")


def report(*words):
	print(*words, flush=True)


def draw(widget, cr):
	if "--animate-full" in sys.argv:
		gradient = cairo.LinearGradient(offset, 0, offset + widget.get_allocated_width(), widget.get_allocated_height())
		gradient.add_color_stop_rgb(0, offset / 600, 0.2, 1 - offset / 600)
		gradient.add_color_stop_rgb(1, 1 - offset / 600, 0.8, offset / 600)
		cr.set_source(gradient)
		cr.paint()
		return
	cr.set_source_rgb(*color)
	cr.paint()
	cr.set_source_rgb(1, 1, 1)
	cr.rectangle(offset, 300, 40, 40)
	cr.fill()


def press(widget, event):
	global color
	report("clicked", event.button, int(event.x), int(event.y))
	if event.button == 1:
		color = (0.0, 1.0, 0.0)
	widget.queue_draw()


def key(_window, event):
	if event.keyval == 0xff1b:
		sys.exit(7)
	return False


def animate(widget):
	global offset
	offset = (offset + 16) % 600
	widget.queue_draw()
	return True


window = Gtk.Window(title="agentos test")
window.set_default_size(1280, 720)
box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
area = Gtk.DrawingArea()
area.add_events(1 << 8)
area.connect("draw", draw)
area.connect("button-press-event", press)
entry = Gtk.Entry()
entry.connect("activate", lambda field: report("text", field.get_text()))
box.pack_start(area, True, True, 0)
box.pack_start(entry, False, False, 0)
window.add(box)
window.connect("key-press-event", key)
window.connect("destroy", lambda *_: sys.exit(0))
window.show_all()
entry.grab_focus()
if "--animate" in sys.argv or "--animate-full" in sys.argv:
	GLib.timeout_add(33, animate, area)
report("ready")
Gtk.main()
