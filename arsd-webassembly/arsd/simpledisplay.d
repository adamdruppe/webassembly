module arsd.simpledisplay;

public import arsd.color;

import arsd.webassembly;

shared static this() { eval("hi there"); }

class SimpleWindow {
	this(int width, int height, string title = "D Application") {
		this.width = width;
		this.height = height;

		element = eval!NativeHandle(q{
			var s = document.getElementById("screen");
			var canvas = document.createElement("canvas");
			canvas.addEventListener("contextmenu", function(event) { event.preventDefault(); });
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
			static if(is(typeof(arg) : void delegate())) {
				sdpy_timer = arg;
			} else static if(is(typeof(arg) : void delegate(KeyEvent))) {
				sdpy_key = arg;
			} else static if(is(typeof(arg) : void delegate(MouseEvent))) {
				sdpy_mouse = arg;
			} else static assert(0, typeof(arg).stringof);
		}

		if(timeout)
		intervalId = eval!int(q{
			return setInterval(function(a) { exports.sdpy_timer_trigger(); }, $0);
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
					case "Up": case "ArrowUp": k = 6; break;
					case " ": k = 7; break;
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
			$0.addEventListener("mousedown", function(event) {
				exports.sdpy_mouse_trigger(1, event.button, event.offsetX, event.offsetY);
			}, true);
			$0.addEventListener("mouseup", function(event) {
				exports.sdpy_mouse_trigger(0, event.button);
			}, true);
		}, element);

	}
}

void delegate() sdpy_timer;
void delegate(KeyEvent) sdpy_key;
void delegate(MouseEvent) sdpy_mouse;

export extern(C) void sdpy_timer_trigger() {
	sdpy_timer();
}
export extern(C) void sdpy_key_trigger(int pressed, int key) {
	KeyEvent ke;
	ke.pressed = pressed ? true : false;
	ke.key = key;
	sdpy_key(ke);
}
export extern(C) void sdpy_mouse_trigger(int pressed, int button, int x, int y) {
	MouseEvent me;
	me.type = pressed ? MouseEventType.buttonPressed : MouseEventType.buttonReleased;
	switch(button) {
		case 0:
			me.button = MouseButton.left;
		break;
		case 1:
			me.button = MouseButton.middle;
		break;
		case 2:
			me.button = MouseButton.right;
		break;
		default:
	}
	me.x = x;
	me.y = y;
	sdpy_mouse(me);

}

struct ScreenPainter {
	this(SimpleWindow window) {
		// no need to arc here tbh
		this.w = window.width;
		this.h = window.height;

		this.element = NativeHandle(window.element.handle, false);
		this.context = eval!NativeHandle(q{
			return $0.getContext("2d");
		}, element);
	}
	@disable this(this); // for now...
	NativeHandle element;
	NativeHandle context;

	private int w, h;

	void clear() {
		eval(q{
			var context = $0;
			context.clearRect(0, 0, $1, $2);
		}, context, w, h);
	}

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
	void drawText(Point p, in char[] txt, Point lowerRight = Point(0, 0), uint alignment = 0) {
		eval(q{
			var context = $0;
			context.font = "18px sans-serif";
			context.strokeText($1, $2, $3 + 16);
		}, context, txt, p.x, p.y);
	}

	void drawLine(Point p1, Point p2) {
		drawLine(p1.x, p1.y, p2.x, p2.y);
	}

	void drawLine(int x1, int y1, int x2, int y2) {
		/*
		console.log($1);
		console.log($2);
		console.log($3);
		console.log($4);
		*/
		eval(q{
			var context = $0;
			context.beginPath();
			context.moveTo($1 + 0.5, $2 + 0.5);
			context.lineTo($3 + 0.5, $4 + 0.5);
			context.closePath();

			context.stroke();
		}, context, x1, y1, x2, y2);
	}
}

struct KeyEvent {
	int key;
	bool pressed;
}

enum MouseEventType : int {
        motion = 0, /// The mouse moved inside the window
        buttonPressed = 1, /// A mouse button was pressed or the wheel was spun
        buttonReleased = 2, /// A mouse button was released
}

struct MouseEvent {
	MouseEventType type;
	int x;
	int y;
	int dx;
	int dy;

	MouseButton button;
	int modifierState;
}

enum MouseButton : int {
        none = 0,
        left = 1, ///
        right = 2, ///
        middle = 4, ///
        wheelUp = 8, ///
        wheelDown = 16, ///
        backButton = 32, /// often found on the thumb and used for back in browsers
        forwardButton = 64, /// often found on the thumb and used for forward in browsers
}

enum TextAlignment : uint {
        Left = 0, ///
        Center = 1, ///
        Right = 2, ///

        VerticalTop = 0, ///
        VerticalCenter = 4, ///
        VerticalBottom = 8, ///
}

enum Key {
	LeftBracket = 1,
	RightBracket,
	Left,
	Right,
	Down,
	Up,
	Space
}
