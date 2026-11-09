FROM dart:stable AS build
WORKDIR /src

# Resolve first, so that source changes reuse the dependency layer.
COPY unpub/pubspec.yaml unpub/pubspec.lock ./
RUN dart pub get --enforce-lockfile

COPY unpub/ ./
RUN dart pub get --offline --enforce-lockfile
RUN mkdir -p /out/app /out/data/packages /out/root/tmp \
    && chmod 1777 /out/root/tmp \
    && dart compile exe bin/unpub.dart -o /out/app/unpub

# /runtime holds the libraries and certificates a compiled Dart program needs.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /out/app /app
# The proxy spools archives for S3 in /tmp, which scratch does not have. Copied
# from its parent, because COPY gives the destination directory a default mode.
COPY --from=build /out/root/ /
COPY --from=build --chown=65532:65532 /out/data /data

WORKDIR /app
USER 65532:65532
ENV UNPUB_STORAGE_FILE_PATH=/data/packages
VOLUME /data
EXPOSE 4000
ENTRYPOINT ["/app/unpub"]
CMD ["serve"]
