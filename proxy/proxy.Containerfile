FROM docker.io/library/perl:latest
EXPOSE 8080
WORKDIR /opt/app
RUN useradd -d /opt/app -M -s /bin/bash app && \
    chown -R app:app /opt/app && \
    cpanm local::lib
USER app
WORKDIR /opt/app
RUN cpanm --local-lib=/opt/app/perl5 local::lib
ADD proxy.pl proxy.pl
ADD cpanfile cpanfile
RUN eval $(perl -I /opt/app/perl5/lib/perl5/ -Mlocal::lib) && \
    cpanm --installdeps -n .

CMD ["bash", "-c", "eval $(perl -I /opt/app/perl5/lib/perl5/ -Mlocal::lib) && hypnotoad -f proxy.pl"]
