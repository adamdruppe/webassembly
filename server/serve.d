/+
	So it needs a HTML bridge, a javascript bridge, then the
	library code in D and javascript.

	D libs in webasm can use the core to call out to JS.

	import arsd.webassembly;

	eval(q{
		// javascript code here
	});

	`eval` returns a value and can take arguments. These are accessible as $0, $1, etc inside.


	eval(q{
		return $0 + $1;
	}, "foo", "bar");

	On the Javascript side, it makes a function with a with:

	(function() {
		with(d_globals[module]) {
			// D inserts these
			$0 = "foo";
			$1 = "bar";

			// this is the user's code
			return $0 + $1;
		}

	})();


	js.foo


	you serve some particular wasm thingy
	with some particular ui.
+/
import arsd.cgi;

import std.file;

void handler(Cgi cgi) {
	if(cgi.pathInfo.length == 0 || cgi.pathInfo == "/") {
		cgi.write(readText("webassembly-skeleton.html"), true);
	} else if(cgi.pathInfo == "/webassembly-core.js") {
		cgi.setResponseContentType("text/javascript");
		cgi.write(readText("webassembly-core.js"), true);
	} else if(cgi.pathInfo == "/omg.wasm") {
		cgi.setResponseContentType("application/wasm");
		cgi.write(read("omg.wasm"), true);
	}
}

mixin GenericMain!handler;
