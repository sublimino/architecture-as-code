.PHONY: test container-test

test:
	PYTHONPATH=. python3 -m unittest discover -s test -v

container-test:
	docker build -t fake-integration-proxy:test .
	./test/container-test.sh fake-integration-proxy:test
