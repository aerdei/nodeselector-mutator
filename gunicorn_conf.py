import os

bind = os.getenv("MUTATOR_BIND", "0.0.0.0:5000")
certfile = os.getenv("MUTATOR_CERT", "server-cert.pem")
keyfile = os.getenv("MUTATOR_KEY", "server-key.pem")
loglevel = os.getenv("MUTATOR_LOGLEVEL", "info")