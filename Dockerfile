FROM debian:trixie-slim

ARG DEPENDENCIES_SCRIPT=./dependencies.sh
ARG PLUGIN_ENTRYPOINT=./plugin/plugin.pl
ARG PLUGIN_ENTRYPOINT_ARGS=""
ARG PLUGIN_DIR=./plugin
ARG STUDENT_CODE_SCRIPT=./student_code.sh
ARG STUDENT_DIR=./student

ENV PLUGIN_ENTRYPOINT_ARGS=$PLUGIN_ENTRYPOINT_ARGS

RUN apt-get update \
	&& apt-get install -y --no-install-recommends sudo procps \
	&& rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 60001 instructor \
	&& useradd -m -u 60002 student \
	&& usermod -aG student instructor

RUN mkdir -m 755 -p /plugin \
	&& mkdir -m 700 -p /plugin/instructor_input /plugin/results \
	&& chown instructor:instructor /plugin/instructor_input /plugin/results \
	&& mkdir -m 750 -p /plugin/student_input \
	&& mkdir -m 770 -p /plugin/work \
	&& chown instructor:student /plugin/student_input /plugin/work

VOLUME /plugin/instructor_input /plugin/student_input /plugin/results

COPY --chmod=0440 sudoers /etc/sudoers

COPY --chown=instructor:student --chmod=750 $PLUGIN_DIR /plugin/plugin_dir/
COPY --chown=instructor:instructor --chmod=700 $PLUGIN_ENTRYPOINT /plugin/entrypoint
COPY --chown=instructor:student --chmod=750 $STUDENT_DIR /plugin/student_dir/
COPY --chown=instructor:student --chmod=550 $STUDENT_CODE_SCRIPT /plugin/student_code

COPY --chmod=0755 $DEPENDENCIES_SCRIPT /tmp/dependencies
RUN /tmp/dependencies && rm /tmp/dependencies

USER instructor
WORKDIR /plugin/work

CMD ["/bin/sh", "-c", "exec /plugin/entrypoint $PLUGIN_ENTRYPOINT_ARGS"]
