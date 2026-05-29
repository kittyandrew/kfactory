package main

func (r *runner) sql(query string) (string, error) {
	return r.ocexec("sqlite3", r.db, query)
}
