'use strict';

var Mt = require("./mt.js");
var $$Array = require("../../lib/js/array.js");
var Block = require("../../lib/js/block.js");
var Ext_filename_test = require("./ext_filename_test.js");

var suites = {
  contents: /* [] */0
};

var test_id = {
  contents: 0
};

function eq(loc, x, y) {
  test_id.contents = test_id.contents + 1 | 0;
  suites.contents = /* :: */[
    /* tuple */[
      loc + (" id " + String(test_id.contents)),
      (function (param) {
          return /* Eq */Block.__(0, [
                    x,
                    y
                  ]);
        })
    ],
    suites.contents
  ];
  return /* () */0;
}

function test(param, param$1) {
  return Ext_filename_test.node_relative_path(true, param, param$1);
}

eq("File \"a_filename_test.ml\", line 10, characters 5-12", /* tuple */[
      Ext_filename_test.combine("/tmp", "subdir/file.txt"),
      Ext_filename_test.combine("/tmp", "/a/tmp.txt"),
      Ext_filename_test.combine("/a/tmp.txt", "subdir/file.txt")
    ], /* tuple */[
      "/tmp/subdir/file.txt",
      "/a/tmp.txt",
      "/a/tmp.txt/subdir/file.txt"
    ]);

eq("File \"a_filename_test.ml\", line 22, characters 5-12", Ext_filename_test.node_relative_path(true, /* `File */[
          781515420,
          "./a/b.c"
        ], /* `File */[
          781515420,
          "./a/u/g.c"
        ]), "./u/g.c");

eq("File \"a_filename_test.ml\", line 27, characters 5-12", Ext_filename_test.node_relative_path(true, /* `File */[
          781515420,
          "./a/b.c"
        ], /* `File */[
          781515420,
          "xxxghsoghos/ghsoghso/node_modules/buckle-stdlib/list.js"
        ]), "buckle-stdlib/list.js");

eq("File \"a_filename_test.ml\", line 33, characters 5-12", Ext_filename_test.node_relative_path(true, /* `File */[
          781515420,
          "./a/b.c"
        ], /* `File */[
          781515420,
          "xxxghsoghos/ghsoghso/node_modules//buckle-stdlib/list.js"
        ]), "buckle-stdlib/list.js");

eq("File \"a_filename_test.ml\", line 39, characters 5-12", Ext_filename_test.node_relative_path(true, /* `File */[
          781515420,
          "./a/b.c"
        ], /* `File */[
          781515420,
          "xxxghsoghos/ghsoghso/node_modules/./buckle-stdlib/list.js"
        ]), "buckle-stdlib/list.js");

eq("File \"a_filename_test.ml\", line 45, characters 5-12", Ext_filename_test.node_relative_path(true, /* `File */[
          781515420,
          "./a/c.js"
        ], /* `File */[
          781515420,
          "./a/b"
        ]), "./b");

eq("File \"a_filename_test.ml\", line 50, characters 5-12", Ext_filename_test.node_relative_path(true, /* `File */[
          781515420,
          "./a/c"
        ], /* `File */[
          781515420,
          "./a/b.js"
        ]), "./b.js");

eq("File \"a_filename_test.ml\", line 55, characters 5-12", Ext_filename_test.node_relative_path(true, /* `Dir */[
          3405101,
          "./a/"
        ], /* `File */[
          781515420,
          "./a/b.js"
        ]), "./b.js");

eq("File \"a_filename_test.ml\", line 60, characters 5-12", Ext_filename_test.get_extension("a.txt"), ".txt");

eq("File \"a_filename_test.ml\", line 64, characters 5-12", Ext_filename_test.get_extension("a"), "");

eq("File \"a_filename_test.ml\", line 68, characters 5-12", Ext_filename_test.get_extension(".txt"), ".txt");

eq("File \"a_filename_test.ml\", line 73, characters 5-12", $$Array.map(Ext_filename_test.normalize_absolute_path, /* array */[
          "/gsho/./..",
          "/a/b/../c../d/e/f",
          "/a/b/../c/../d/e/f",
          "/gsho/./../..",
          "/a/b/c/d",
          "/a/b/c/d/",
          "/a/",
          "/a",
          "/a.txt/",
          "/a.txt"
        ]), /* array */[
      "/",
      "/a/c../d/e/f",
      "/a/d/e/f",
      "/",
      "/a/b/c/d",
      "/a/b/c/d",
      "/a",
      "/a",
      "/a.txt",
      "/a.txt"
    ]);

Mt.from_pair_suites("A_filename_test", suites.contents);

exports.suites = suites;
exports.test_id = test_id;
exports.eq = eq;
exports.test = test;
/*  Not a pure module */
