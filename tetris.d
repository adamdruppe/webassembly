import arsd.simpledisplay;
import arsd.simpleaudio;

enum PieceSize = 16;

enum SettleStatus {
	none,
	settled,
	cleared,
	tetris,
	gameOver,
}

class Board {
	int width;
	int height;
	int[] state;
	int score;
	this(int width, int height) {
		state = new int[](width * height);
		this.width = width;
		this.height = height;
	}

	SettleStatus settlePiece(Piece piece) {
		if(piece.y <= 0)
			return SettleStatus.gameOver;

		SettleStatus status = SettleStatus.settled;
		foreach(yo, line; pieces[piece.type][piece.rotation]) {
			int mline = line;
			foreach(xo; 0 .. 4) {
				if(mline & 0b1000)
					state[(piece.y+yo) * width + xo + piece.x] = piece.type + 1;
				mline <<= 1;
			}
		}

		int[4] del;
		int delPos = 0;

		foreach(y; piece.y .. piece.y + 4) {
			int presentCount;
			if(y >= height)
				break;
			foreach(x; 0 .. width)
				if(state[y * width + x])
					presentCount++;

			if(presentCount == width) {
				del[delPos++] = y;
				status = SettleStatus.cleared;
			}
		}

		if(delPos == 4) {
			score += 4; // tetris bonus!
			status = SettleStatus.tetris;
		}

		foreach(p; 0 .. delPos) {
			foreach_reverse(y; 0 .. del[p])
				state[(y + 1) * width .. (y + 2) * width] = state[(y + 0) * width .. (y + 1) * width];
			state[0 .. width] = 0;

			score++;
		}

		return status;

		/+
		import std.stdio;
		writeln;
		writeln;
		foreach(y; 0 .. height) {
			foreach(x; 0 .. width) {
				write(state[y * width + x]);
			}
			writeln("");
		}
		+/
	}

	SettleStatus trySettle(Piece piece) {
		auto pieceMap = pieces[piece.type][piece.rotation];
		int ph = 4;
		foreach_reverse(line; pieceMap) {
			if(line)
				break;
			ph--;
		}
		if(ph + piece.y >= this.height) {
			if(!piece.settleNextFrame) {
				piece.settleNextFrame = true;
				return SettleStatus.none;
			} else {
				return settlePiece(piece);
			}
		}
		piece.y++;
		if(collisionDetect(piece)) {
			piece.y--;

			if(!piece.settleNextFrame) {
				piece.settleNextFrame = true;
				return SettleStatus.none;
			} else {
				return settlePiece(piece);
			}
		} else {
			piece.settleNextFrame = false;
		}
		piece.y--;
		return SettleStatus.none;
	}

	bool collisionDetect(Piece piece) {
		auto pieceMap = pieces[piece.type][piece.rotation];
		foreach_reverse(yo,line; pieceMap) {
			int mline = line;
			foreach(xo; 0 .. 4) {
				if(mline & 0b1000) {
					if(state[(piece.y+yo) * this.width + xo + piece.x])
						return true;
				}
				mline <<= 1;
			}
		}
		return false;
	}

	void redraw(SimpleWindow window) {
		auto painter = window.draw();
		int x, y;
		foreach(s; state) {
			painter.fillColor = s ? palette[s - 1] : Color.black;
			painter.outlineColor = s ? Color.white : Color.black;
			painter.drawRectangle(Point(x, y) * PieceSize, PieceSize, PieceSize);
			x++;
			if(x == width) {
				x = 0;
				y++;
			}
		}
	}
}

static immutable ubyte[][][] pieces = [
	// long straight
	[[0b1000,
	  0b1000,
	  0b1000,
	  0b1000],
	 [0b1111,
	  0b0000,
	  0b0000,
	  0b0000]],
	 // l
	[[0b1000,
	  0b1000,
	  0b1100,
	  0b0000],
	 [0b0010,
	  0b1110,
	  0b0000,
	  0b0000],
	 [0b1100,
	  0b0100,
	  0b0100,
	  0b0000],
	 [0b1110,
	  0b1000,
	  0b0000,
	  0b0000]],
	 // j
	[[0b0100,
	  0b0100,
	  0b1100,
	  0b0000],
	 [0b1000,
	  0b1110,
	  0b0000,
	  0b0000],
	 [0b1100,
	  0b1000,
	  0b1000,
	  0b0000],
	 [0b1110,
	  0b0010,
	  0b0000,
	  0b0000]],
	 // n
	[[0b1100,
	  0b0110,
	  0b0000,
	  0b0000],
	 [0b0100,
	  0b1100,
	  0b1000,
	  0b0000]],
	 // other n
	[[0b0110,
	  0b1100,
	  0b0000,
	  0b0000],
	 [0b1000,
	  0b1100,
	  0b0100,
	  0b0000]],
	 // t
	[[0b0100,
	  0b1110,
	  0b0000,
	  0b0000],
	 [0b1000,
	  0b1100,
	  0b1000,
	  0b0000],
	 [0b1110,
	  0b0100,
	  0b0000,
	  0b0000],
	 [0b0100,
	  0b1100,
	  0b0100,
	  0b0000]],
	// square
	[[0b1100,
	  0b1100,
	  0b0000,
	  0b0000]],
];

immutable Color[] palette = [
	Color.red,
	Color.blue,
	Color.green,
	Color.yellow,
	Color.teal,
	Color.purple,
	Color.gray
];

static assert(palette.length == pieces.length);

class Piece {
	SimpleWindow window;
	Board board;
	this(SimpleWindow window, Board board) {
		this.window = window;
		this.board = board;
	}

	static int randomType() {
		import std.random;
		return uniform(0, cast(int) pieces.length);
	}

	int width() {
		int fw = 0;
		foreach(int s; pieces[type][rotation]) {
			int w = 4;
			while(w && ((s & 1) == 0)) {
				w--;
				s >>= 1;
			}
			if(w > fw)
				fw = w;
		}
		return fw;
	}

	void reset(int type) {
		this.type = type;
		rotation = 0;
		x = board.width / 2 - 1;
		y = 0;
		settleNextFrame = false;
	}

	int type;
	int rotation;

	int x;
	int y;

	bool settleNextFrame;

	void erase() {
		draw(true);
	}

	void draw(bool erase = false) {
		auto painter = window.draw();
		painter.fillColor = erase ? Color.black : palette[type];
		painter.outlineColor = erase ? Color.black : Color.white;
		foreach(yo, line; pieces[type][rotation]) {
			int mline = line;
			foreach(xo; 0 .. 4) {
				if(mline & 0b1000)
					painter.drawRectangle(Point(cast(int) (x + xo), cast(int) (y + yo)) * PieceSize, PieceSize, PieceSize);
				mline <<= 1;
			}
		}
	}

	void moveDown() {
		if(!settleNextFrame) {
			y++;
			if(board.collisionDetect(this))
				y--;
		}
	}

	void moveLeft() {
		if(x) {
			x--;
			if(board.collisionDetect(this))
				x++;
		}
	}

	void moveRight() {
		if(x + width < board.width) {
			x++;
			if(board.collisionDetect(this))
				x--;
		}
	}

	void rotate() {
		rotation++;
		if(rotation >= pieces[type].length)
			rotation = 0;
		if(x + width > board.width)
			x = board.width - width;
	}
}

void main() {
	auto audio = AudioOutputThread(0);
	audio.start();

	auto board = new Board(10, 20);

	auto window = new SimpleWindow(board.width * PieceSize, board.height * PieceSize, "Detris");

	// clear screen to black
	{
		auto painter = window.draw();
		painter.outlineColor = Color.black;
		painter.fillColor = Color.black;
		painter.drawRectangle(Point(0, 0), Size(window.width, window.height));
	}

	Piece currentPiece = new Piece(window, board);

	int frameCounter;
	bool downPressed;

	int gameOverY = 0;

	int difficulty = 1;

	window.eventLoop(100 / 5, () {

		if(gameOverY > board.height + 1) {
			window.close();
			return;
		}

		if(frameCounter <= 0) {
			if(gameOverY == 0) {
				currentPiece.erase();
				currentPiece.moveDown();
				currentPiece.draw();
			}
			auto sb = board.score;
			bool donew = false;
			final switch (board.trySettle(currentPiece)) {
				case SettleStatus.none:
				break;
				case SettleStatus.settled:
					audio.beep(400);
					donew = true;
				break;
				case SettleStatus.cleared:
					audio.beep(1100);
					audio.beep(400);
					donew = true;
				break;
				case SettleStatus.tetris:
					audio.beep(1200);
					audio.beep(400);
					audio.beep(700);
					donew = true;
				break;
				case SettleStatus.gameOver:
					audio.boop();

					auto painter = window.draw();
					painter.outlineColor = Color.white;
					painter.fillColor = Color(127, 127, 127);
					painter.drawRectangle(Point(0, 0), Size(window.width, (gameOverY + 1) * PieceSize));
					gameOverY++;
				break;
			}

			if(donew) {
				currentPiece.reset(Piece.randomType());
				if(board.score != sb)
					board.redraw(window);
			}

			frameCounter = 2 * 5 * 3;
		}

		if(downPressed)
			frameCounter -= 12;
		frameCounter -= difficulty;
	}, (KeyEvent kev) {
		if(kev.key == Key.Down)
			downPressed = kev.pressed;
		if(!kev.pressed) return;
		switch(kev.key) {
			case Key.Space:
				currentPiece.erase();
				currentPiece.rotate();
				currentPiece.draw();
				audio.beep(1100);
				audio.beep(1000);
			break;
			case Key.Left:
				currentPiece.erase();
				currentPiece.moveLeft();
				currentPiece.draw();
			break;
			case Key.Right:
				currentPiece.erase();
				currentPiece.moveRight();
				currentPiece.draw();
			break;
			case Key.LeftBracket:
				if(difficulty)
					difficulty--;
			break;
			case Key.RightBracket:
				if(difficulty < 10)
					difficulty++;
			break;
			default:
		}
	});

	import std.stdio;
	writeln(board.score);
}
