.PHONY: test container-test

test:
	PYTHONPATH=. python3 -m unittest discover -s test -v

container-test:
	docker build -t netassert-controller:test .
	./test/container-test.sh netassert-controller:test
