## Licensed under the Apache License, Version 2.0 (the "License"); you may not
## use this file except in compliance with the License. You may obtain a copy of
## the License at
##
##   http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
## WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
## License for the specific language governing permissions and limitations under
## the License.

noinst_SCRIPTS = run
noinst_DATA = test_util.beam test_web.beam

noinst_PROGRAMS = test_cfg_register
test_cfg_register_SOURCES = test_cfg_register.c
test_cfg_register_CFLAGS = -D_BSD_SOURCE

%.beam: %.erl
	$(ERLC) $<

run: run.tpl
	sed -e "s|%abs_top_srcdir%|@abs_top_srcdir@|g" \
	    -e "s|%abs_top_builddir%|@abs_top_builddir@|g" > \
	$@ < $<
	chmod +x $@

CLEANFILES = run *.beam
DISTCLEANFILES = temp.*

EXTRA_DIST = \
    run.tpl \
    test_web.erl \
    random_port.ini \
    001-load.t \
    002-icu-driver.t \
    010-file-basics.t \
    011-file-headers.t \
    020-btree-basics.t \
    021-btree-reductions.t \
    022-btree-copy.t \
    023-btree-guided-purge.t \
    024-btree-guided-fold.t \
    030-doc-from-json.t \
    031-doc-to-json.t \
    040-util.t \
    041-uuid-gen-seq.ini \
    041-uuid-gen-utc.ini \
    041-uuid-gen.t \
    042-work-queue.t \
    070-couch-db.t \
    071-couch-db-external-write.t \
    073-changes.t \
    080-config-get-set.t \
    081-config-override.1.ini \
    081-config-override.2.ini \
    081-config-override.t \
    082-config-register.t \
    083-config-no-files.t \
    090-task-status.t \
    100-ref-counter.t \
    150-invalid-view-seq.t \
    190-json-stream-parse.t \
    200-view-group-no-db-leaks.t \
    201-view-group-shutdown.t
