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

	static immutable Color white = Color(255, 255, 255, 255);
	static immutable Color black = Color(0, 0, 0, 255);
	static immutable Color red = Color(255, 0, 0, 255);
	static immutable Color blue = Color(0, 0, 255, 255);
	static immutable Color green = Color(0, 255, 0, 255);
	static immutable Color yellow = Color(255, 255, 0, 255);
	static immutable Color teal = Color(0, 255, 255, 255);
	static immutable Color purple = Color(255, 0, 255, 255);
	static immutable Color gray = Color(127, 127, 127, 255);
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
