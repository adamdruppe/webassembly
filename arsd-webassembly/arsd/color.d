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

struct Rectangle {}

enum arsd_jsvar_compatible = "arsd_jsvar_compatible";
class MemoryImage {}
