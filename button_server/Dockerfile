FROM balenalib/raspberry-pi-debian:bookworm

# Install system dependencies and build tools
RUN apt-get update && apt-get install -y \
	build-essential \
	wget \
	libdbi-perl \
	libdbd-mysql-perl \
	cpanminus \
	&& rm -rf /var/lib/apt/lists/*

# Download and compile the bcm2835 C library for GPIO access
RUN wget http://www.airspayce.com/mikem/bcm2835/bcm2835-1.71.tar.gz && \
	tar zxvf bcm2835-1.71.tar.gz && \
	cd bcm2835-1.71 && ./configure && make && make install && \
	cd .. && rm -rf bcm2835-1.71*

# Install Perl modules via CPAN
RUN cpanm Device::BCM2835 Redis

# Copy files into system paths
COPY perl/LockServer/ /usr/local/share/perl5/LockServer/
COPY perl/button_server.pl /usr/local/bin/button_server.pl
RUN chmod +x /usr/local/bin/button_server.pl

CMD ["/usr/local/bin/button_server.pl"]
