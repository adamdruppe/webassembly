module arsd.color;

char toHex(int a) {
	if(a < 10)
		return cast(char) (a + '0');
	else
		return cast(char) (a - 10 + 'a');
}

struct Color {
	int r, g, b, a;
	this(int r, int g, int b, int a = 255) {
		this.r = r;
		this.g = g;
		this.b = b;
		this.a = a;
	}

	void toTempString(char[] data) {
		data[0] = '#';
		data[1] = toHex(r >> 4);
		data[2] = toHex(r & 0x0f);
		data[3] = toHex(g >> 4);
		data[4] = toHex(g & 0x0f);
		data[5] = toHex(b >> 4);
		data[6] = toHex(b & 0x0f);
	}

	static Color fromHsl(double h, double s, double l, double a = 255) {
		h = h % 360;

		double C = (1 - absInternal(2 * l - 1)) * s;

		double hPrime = h / 60;

		double X = C * (1 - absInternal(hPrime % 2 - 1));

		double r, g, b;

		if(h is double.nan)
			r = g = b = 0;
		else if (hPrime >= 0 && hPrime < 1) {
			r = C;
			g = X;
			b = 0;
		} else if (hPrime >= 1 && hPrime < 2) {
			r = X;
			g = C;
			b = 0;
		} else if (hPrime >= 2 && hPrime < 3) {
			r = 0;
			g = C;
			b = X;
		} else if (hPrime >= 3 && hPrime < 4) {
			r = 0;
			g = X;
			b = C;
		} else if (hPrime >= 4 && hPrime < 5) {
			r = X;
			g = 0;
			b = C;
		} else if (hPrime >= 5 && hPrime < 6) {
			r = C;
			g = 0;
			b = X;
		}

		double m = l - C / 2;

		r += m;
		g += m;
		b += m;

		return Color(
			cast(int)(r * 255),
			cast(int)(g * 255),
			cast(int)(b * 255),
			cast(int)(a));
	}

	static immutable Color white = Color(255, 255, 255, 255);
	static immutable Color black = Color(0, 0, 0, 255);
	static immutable Color red = Color(255, 0, 0, 255);
	static immutable Color blue = Color(0, 0, 255, 255);
	static immutable Color green = Color(0, 255, 0, 255);
	static immutable Color yellow = Color(255, 255, 0, 255);
	static immutable Color teal = Color(0, 255, 255, 255);
	static immutable Color purple = Color(255, 0, 255, 255);
	static immutable Color gray = Color(127, 127, 127, 255);
	static immutable Color transparent = Color(0, 0, 0, 0);
}

struct Point {
	int x;
	int y;

        pure const nothrow @safe:

	Point opBinary(string op)(in Point rhs) @nogc {
		return Point(mixin("x" ~ op ~ "rhs.x"), mixin("y" ~ op ~ "rhs.y"));
	}

	Point opBinary(string op)(int rhs) @nogc {
		return Point(mixin("x" ~ op ~ "rhs"), mixin("y" ~ op ~ "rhs"));
	}

}

struct Size {
	int width;
	int height;
}


nothrow @safe @nogc pure
double absInternal(double a) { return a < 0 ? -a : a; }

struct Rectangle {
	int left; ///
	int top; ///
	int right; ///
	int bottom; ///

	pure const nothrow @safe @nogc:

	///
	this(int left, int top, int right, int bottom) {
		this.left = left;
		this.top = top;
		this.right = right;
		this.bottom = bottom;
	}

	///
	this(in Point upperLeft, in Point lowerRight) {
		this(upperLeft.x, upperLeft.y, lowerRight.x, lowerRight.y);
	}

	///
	this(in Point upperLeft, in Size size) {
		this(upperLeft.x, upperLeft.y, upperLeft.x + size.width, upperLeft.y + size.height);
	}

	///
	@property Point upperLeft() {
		return Point(left, top);
	}

	///
	@property Point upperRight() {
		return Point(right, top);
	}

	///
	@property Point lowerLeft() {
		return Point(left, bottom);
	}

	///
	@property Point lowerRight() {
		return Point(right, bottom);
	}

	///
	@property Point center() {
		return Point((right + left) / 2, (bottom + top) / 2);
	}

	///
	@property Size size() {
		return Size(width, height);
	}

	///
	@property int width() {
		return right - left;
	}

	///
	@property int height() {
		return bottom - top;
	}

	/// Returns true if this rectangle entirely contains the other
	bool contains(in Rectangle r) {
		return contains(r.upperLeft) && contains(r.lowerRight);
	}

	/// ditto
	bool contains(in Point p) {
		return (p.x >= left && p.x < right && p.y >= top && p.y < bottom);
	}

	/// Returns true of the two rectangles at any point overlap
	bool overlaps(in Rectangle r) {
		// the -1 in here are because right and top are exclusive
		return !((right-1) < r.left || (r.right-1) < left || (bottom-1) < r.top || (r.bottom-1) < top);
	}

	/++
		Returns a Rectangle representing the intersection of this and the other given one.

		History:
			Added July 1, 2021
	+/
	Rectangle intersectionOf(in Rectangle r) {
		auto tmp = Rectangle(max(left, r.left), max(top, r.top), min(right, r.right), min(bottom, r.bottom));
		if(tmp.left >= tmp.right || tmp.top >= tmp.bottom)
			tmp = Rectangle.init;

		return tmp;
	}
}

private int max(int a, int b) @nogc nothrow pure @safe {
	return a >= b ? a : b;
}
private int min(int a, int b) @nogc nothrow pure @safe {
	return a <= b ? a : b;
}


enum arsd_jsvar_compatible = "arsd_jsvar_compatible";
class MemoryImage {}
