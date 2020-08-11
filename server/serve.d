import arsd.cgi;

import std.file;
import std.string;
import std.process;

void handler(Cgi cgi) {

	if(cgi.pathInfo == "/webassembly-core.js") {
		cgi.setResponseContentType("text/javascript");
		cgi.write(readText("webassembly-core.js"), true);
		return;
	}


	// lol trivial validation
	size_t dot;
	{
		if(cgi.pathInfo.length > 32) return;
		foreach(idx, ch; cgi.pathInfo[1 .. $]) {
			if(!(
				(ch >= '0' && ch <= '9') ||
				(ch >= 'A' && ch <= 'Z') ||
				(ch >= 'a' && ch <= 'z') ||
				ch == '_' ||
				ch == '.'
			)) return;
			if(ch == '.') {
				if(idx == 0) return;
				if(dot) return;
				dot = idx;
			}
		}
	}

	auto path = cgi.pathInfo.length == 0 ? "" : cgi.pathInfo[1 .. $];

	if(dot && path[dot .. $] == ".wasm") {
		cgi.setResponseContentType("application/wasm");
		cgi.write(read("../" ~ path), true);
		return;

	}

	if(path.length == 0) {
		// index
		string html = "<html><head><title>Webassembly in D</title></head><body><ul>";
		foreach(string name; dirEntries("..", "*.d", SpanMode.shallow))
			html ~= "<li><a href=\"" ~ name[3 .. $-2] ~ "\">" ~ name[3 .. $] ~"</a></li>";

		html ~= "</ul></body></html>";
		cgi.write(html, true);
		return;
	}

	if(dot && path[dot .. $] == ".d") {
		cgi.setResponseContentType("text/plain");
		cgi.write(readText("../" ~ path), true);
		return;

	}

	if(dot)
		return;

	// otherwise, compile and serve!
	if(!exists("../" ~ path ~ ".d")) {
		cgi.write("404");
		return;
	}

	if(!exists("../" ~ path ~ ".wasm") || cgi.requestMethod == Cgi.RequestMethod.POST) {
		auto res = executeShell("ldc2 -i=. -i=std -Iarsd-webassembly/ -L-allow-undefined -of"~path~".wasm -mtriple=wasm32-unknown-unknown-wasm "~path~".d arsd-webassembly/object.d",
			null,
			Config.none,
			64_000,
			".."
		);
		if(res.status == 0) {
			// yay
		} else {
			cgi.setResponseContentType("text/plain");
			cgi.write(res.output);
			return;
		}
	}

	cgi.write(readText("webassembly-skeleton.html").replace("omg", path), true);

}

mixin GenericMain!handler;
