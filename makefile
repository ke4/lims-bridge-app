.PHONY: migrate_test serve
migrate_test:
	rm test.db ; cat db/test/sequencescape_samples.sql | sqlite3 test.db
