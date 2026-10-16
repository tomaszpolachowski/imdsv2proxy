FROM docker.io/library/perl:latest
WORKDIR /opt/app
ADD cpanfile cpanfile
ADD firewall.pl firewall.pl
RUN apt-get update -y && \
    apt-get install -y libnftables-dev && \
    apt-get clean -y && \
    cpanm -n --installdeps -n .
CMD ["perl", "-w", "firewall.pl"]
