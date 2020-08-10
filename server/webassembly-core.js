
// can webassembly's main be async?

// stores { object: o, refcount: n }
var bridgeObjects = [{}]; // the first one is a null object; ignored
// placeholder to be filled in by the loader
var memory;

var bridge_malloc;

var dModules = {};

var exports;

var importObject = {
    env: {
	memorySize: function() { return memory.buffer.byteLength; },
	growMemory: function(by) {
		const bytesPerPage = 64 * 1024;
		memory.grow((by + bytesPerPage) / bytesPerPage);
		return memory.buffer.byteLength;
	},

	acquire: function(returnType, modlen, modptr, javascriptCodeStringLength, javascriptCodeStringPointer, argsLength, argsPtr) {
		var td = new TextDecoder();
		var md = td.decode(new Uint8Array(memory.buffer, modptr, modlen));
		var s = td.decode(new Uint8Array(memory.buffer, javascriptCodeStringPointer, javascriptCodeStringLength));

		var jsArgs = [];
		var argIdx = 0;

		var jsArgsNames = "";

		var a = new Uint32Array(memory.buffer, argsPtr, argsLength * 3);
		var aidx = 0;

		for(var argIdx = 0; argIdx < argsLength; argIdx++) {
			var type = a[aidx];
			aidx++;
			var ptr = a[aidx];
			aidx++;
			var length = a[aidx];
			aidx++;

			if(jsArgsNames.length)
				jsArgsNames += ", ";
			jsArgsNames += "$" + argIdx;

			var value;

			switch(type) {
				case 0:
					// an integer was casted to the pointer
					value = ptr;
				break;
				case 1:
					// pointer+length is a string
					value = td.decode(new Uint8Array(memory.buffer, ptr, length));
				break;
				case 2:
					// a handle
					value = bridgeObjects[ptr].object;
				break;
			}

			jsArgs.push(value);
		}

		var func = new Function(jsArgsNames, s);
		var ret = func.apply(dModules[md] ? dModules[md] : (dModules[md] = {}), jsArgs);

		switch(returnType) {
			case 0: // void
				return 0;
			case 1:
				// int
				return ret;
			case 2:
				// float
			case 3:
				// boxed object
				var handle = bridgeObjects.length;
				bridgeObjects.push({ refcount: 1, object: ret });
				return handle;
			case 4:
				// ubyte[] into given buffer
			case 5:
				// malloc'd ubyte[]
			case 6:
				// string into given buffer
			case 7:
				// malloc'd string. it puts the length as an int before the string, then returns the pointer.
				var te = new TextEncoder();
				var s = te.encode(ret);
				var ptr = bridge_malloc(s.byteLength + 4);
				var view = new Uint32Array(memory.buffer, ptr, 1);
				view[0] = s.byteLength;
				var view2 = new Uint8Array(memory.buffer, ptr + 4, s.length);
				view2.set(s);
				return ptr;
			case 8:
				// return the function itself, so box it up but do not actually call it
		}
		return -1;
	},

	retain: function(handle) {
		bridgeObjects[handle].refcount++;
	},
	release: function(handle) {
		bridgeObjects[handle].refcount--;
		if(bridgeObjects[handle].refcount <= 0) {
			//console.log("freeing " + handle);
			bridgeObjects[handle] = null;
			if(handle + 1 == bridgeObjects.length)
				bridgeObjects.pop();
		}
	},
	abort: function() { throw "aborted"; },
	_Unwind_Resume: function() {}
    }
};
