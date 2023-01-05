module std.stdio;

import arsd.webassembly;

void writeln(T...)(T t) {
	eval(q{
		console.log.apply(null, arguments);
	}, t);
}
