FROM rocker/r-ver:4.5.2

# Install Java 17 and system dependencies for R packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    openjdk-17-jdk-headless \
    libxml2-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libcairo2-dev \
    libfontconfig1-dev \
    libharfbuzz-dev \
    libfribidi-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    libgit2-dev \
    git \
    curl \
    wget \
    unzip \
    xz-utils \
    cmake \
    pandoc \
    libx11-dev \
    && rm -rf /var/lib/apt/lists/*

# Create a stable JAVA_HOME symlink that works on both amd64 and arm64
RUN ARCH=$(dpkg --print-architecture) && \
    ln -s /usr/lib/jvm/java-17-openjdk-${ARCH} /usr/lib/jvm/java-17

ENV JAVA_HOME=/usr/lib/jvm/java-17
ENV PATH="$JAVA_HOME/bin:$PATH"

# Configure R to use Java 17
RUN R CMD javareconf

# Install renv for package management
RUN R -e "install.packages('renv', repos = 'https://cloud.r-project.org')"
