FROM arm32v5/debian:buster-slim

# Fix the dead upstream Debian Buster archive mirrors inside the container
RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
	sed -i 's/security.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
	sed -i '/debian-updates/d' /etc/apt/sources.list

# Install system dependencies and build tools
RUN apt-get update && apt-get install -y \
	build-essential \
	libdbi-perl \
	libdbd-mysql-perl \
	libdevice-serialport-perl \
	cpanminus \
	&& rm -rf /var/lib/apt/lists/*

# Install Redis client driver via CPAN
RUN cpanm Redis

# Copy files into system paths
COPY perl/LockServer/ /usr/local/share/perl5/LockServer/
COPY perl/rfid_server.pl /usr/local/bin/rfid_server.pl
RUN chmod +x /usr/local/bin/rfid_server.pl

CMD ["/usr/local/bin/rfid_server.pl"]
