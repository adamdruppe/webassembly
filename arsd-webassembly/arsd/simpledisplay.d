module arsd.simpledisplay;

public import arsd.color;

import arsd.webassembly;

//shared static this() { eval("hi there"); }

// the js bridge is SO EXPENSIVE we have to minimize using it.

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

		canvasContext = eval!NativeHandle(q{
			return $0.getContext("2d");
		}, element);
	}

	NativeHandle element;
	NativeHandle canvasContext;
	int width;
	int height;

	void close() {
		eval(q{ clearInterval($0); }, intervalId);
		intervalId = 0;
	}

	void delegate() onClosing;

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
				event.preventDefault();
			}, true);
			document.body.addEventListener("keyup", function(event) {
				exports.sdpy_key_trigger(0, translate(event.key));
				event.preventDefault();
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
	if(sdpy_key)
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
	if(sdpy_mouse)
		sdpy_mouse(me);

}


// push arguments in reverse order then push the command
enum canvasRender = q{
};

struct ScreenPainter {
	this(SimpleWindow window) {
		// no need to arc here tbh
		this.w = window.width;
		this.h = window.height;

		this.element = NativeHandle(window.element.handle, false);
		this.context = NativeHandle(window.canvasContext.handle, false);
	}
	@disable this(this); // for now...
	NativeHandle element;
	NativeHandle context;

	private int w, h;

	void clear() {
		addCommand(1);
	}

	void outlineColor(Color c) {
		char[7] data;
		c.toTempString(data[]);
		addCommand(2, 7, data[0], data[1], data[2], data[3], data[4], data[5], data[6]);
		return;
		//context.properties.strokeStyle!string = cast(immutable)(data[]);
	}
	void fillColor(Color c) {
		char[7] data;
		c.toTempString(data[]);
		addCommand(3, 7, data[0], data[1], data[2], data[3], data[4], data[5], data[6]);
		return;
		//context.properties.fillStyle!string = cast(immutable)(data[]);
	}

	void drawPolygon(Point[] points) {
		addCommand(8);
		addCommand(cast(double) points.length);
		foreach(point; points) {
			push(cast(double) point.x);
			push(cast(double) point.y);
		}
	}

	void drawRectangle(Point p, int w, int h) {
		addCommand(4, p.x, p.y, w, h);
	}
	void drawRectangle(Point p, Size s) {
		drawRectangle(p, s.width, s.height);
	}
	void drawText(Point p, in char[] txt, Point lowerRight = Point(0, 0), uint alignment = 0) {
		// FIXME use the new system
		addCommand(5, p.x, p.y + 16, txt.length);
		foreach(c; txt)
			push(cast(double) c);
		return;
		eval(q{
			var context = $0;
			context.font = "18px sans-serif";
			context.strokeText($1, $2, $3 + 16);
		}, context, txt, p.x, p.y);
	}

	void drawCircle(Point upperLeft, int diameter) {
		addCommand(6, upperLeft.x + diameter / 2, upperLeft.y + diameter / 2, diameter / 2);
	}

	void drawLine(Point p1, Point p2) {
		drawLine(p1.x, p1.y, p2.x, p2.y);
	}

	void drawLine(int x1, int y1, int x2, int y2) {
		addCommand(7, x1, y1, x2, y2);
	}

	private:
	void addCommand(T...)(int cmd, T args) {
		push(cmd);
		foreach(arg; args) {
			push(arg);
		}
	}

	// 50ish % on ronaroids total cpu without this
	// with it, we at like 16%
	static __gshared double[] commandStack;
	size_t commandStackPosition;

	void push(T)(T t) {
		if(commandStackPosition == commandStack.length) {
			commandStack.length = commandStack.length + 1024;
			commandStack.assumeUniqueReference();
		}

		commandStack[commandStackPosition++] = t;
	}

	~this() {
		executeCanvasCommands(this.context.handle, this.commandStack.ptr, commandStackPosition);
	}
}

extern(C) void executeCanvasCommands(int handle, double* start, size_t len);

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

enum MouseCursor { cross }

class OperatingSystemFont {}
enum UsingSimpledisplayX11 = false;
enum SimpledisplayTimerAvailable = false;


class Sprite{}

enum bool OpenGlEnabled = false;

alias ScreenPainterImplementation = ScreenPainter;

mixin template ExperimentalTextComponent() {
	class TextLayout {

	}
}
