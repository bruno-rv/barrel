.PHONY: app run verify clean

app:
	./script/build_and_run.sh

run: app

verify:
	./script/build_and_run.sh --verify

clean:
	rm -rf .build dist
