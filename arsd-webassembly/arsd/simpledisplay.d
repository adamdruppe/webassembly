module arsd.simpledisplay;

public import arsd.color;

import arsd.webassembly;

class SimpleWindow {
	this(int width, int height, string title) {
		this.width = width;
		this.height = height;

		element = eval!NativeHandle(q{
			var s = document.getElementById("screen");
			var canvas = document.createElement("canvas");
			canvas.setAttribute("width", $0);
			canvas.setAttribute("height", $1);
			canvas.setAttribute("title", $2);
			s.appendChild(canvas);
			return canvas;
		}, width, height, title);
	}

	NativeHandle element;
	int width;
	int height;

	void close() {
		eval(q{ clearInterval($0); }, intervalId);
		intervalId = 0;
	}

	ScreenPainter draw() {
		return ScreenPainter(this);
	}

	int intervalId;

	void eventLoop(T...)(int timeout, T t) {
		foreach(arg; t) {
			static if(is(typeof(arg) == void delegate())) {
				sdpy_timer = arg;
			} else static if(is(typeof(arg) == void delegate(KeyEvent))) {
				sdpy_key = arg;
			} else static assert(0);
		}

		intervalId = eval!int(q{
			return setInterval(exports.sdpy_timer_trigger, $0);
		}, timeout);

		eval(q{
			function translate(key) {
				var k = 0;
				switch(key) {
					case "[": k = 1; break;
					case "]": k = 2; break;
					case "Left": case "ArrowLeft": k = 3; break;
					case "Right": case "ArrowRight": k = 4; break;
					case "Down": case "ArrowDown": k = 5; break;
					case " ": k = 6; break;
					// "Enter", "Esc" / "Escape"
					default: k = 0;
				}
				return k;
			}
			document.body.addEventListener("keydown", function(event) {
				exports.sdpy_key_trigger(1, translate(event.key));
			}, true);
			document.body.addEventListener("keyup", function(event) {
				exports.sdpy_key_trigger(0, translate(event.key));
			}, true);
		});

	}
}

void delegate() sdpy_timer;
void delegate(KeyEvent) sdpy_key;

extern(C) void sdpy_timer_trigger() {
	sdpy_timer();
}
extern(C) void sdpy_key_trigger(int pressed, int key) {
	KeyEvent ke;
	ke.pressed = pressed ? true : false;
	ke.key = key;
	sdpy_key(ke);
}

struct ScreenPainter {
	this(SimpleWindow window) {
		// no need to arc here tbh
		this.element = NativeHandle(window.element.handle, false);
		this.context = eval!NativeHandle(q{
			return $0.getContext("2d");
		}, element);
	}
	@disable this(this); // for now...
	NativeHandle element;
	NativeHandle context;

	void outlineColor(Color c) {
		char[7] data;
		c.toTempString(data[]);
		context.properties.strokeStyle!string = cast(immutable)(data[]);
	}
	void fillColor(Color c) {
		char[7] data;
		c.toTempString(data[]);
		context.properties.fillStyle!string = cast(immutable)(data[]);
	}

	void drawRectangle(Point p, int w, int h) {
		eval(q{
			var context = $0;
			context.beginPath();
			context.rect($1 + 0.5, $2 + 0.5, $3 - 1, $4 - 1);
			context.closePath();

			context.stroke();
			context.fill();
		}, context, p.x, p.y, w, h);
	}
	void drawRectangle(Point p, Size s) {
		drawRectangle(p, s.width, s.height);
	}
}

struct KeyEvent {
	int key;
	bool pressed;
}

enum Key {
	LeftBracket = 1,
	RightBracket,
	Left,
	Right,
	Down,
	Space
}
