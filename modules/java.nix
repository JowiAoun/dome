{ config, lib, pkgs, ... }:

let
  cfg = config.modules.java;
in
{
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      jdk21
      maven
      gradle
      spring-boot-cli
      visualvm
    ];

    home.sessionVariables = {
      JAVA_HOME = "${pkgs.jdk21}/lib/openjdk";
      MAVEN_HOME = "${pkgs.maven}";
      GRADLE_HOME = "${pkgs.gradle}";
    };

    home.file.".m2/settings.xml".text = ''
      <?xml version="1.0" encoding="UTF-8"?>
      <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"
                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 
                                    http://maven.apache.org/xsd/settings-1.0.0.xsd">
        <localRepository>~/.m2/repository</localRepository>
        <interactiveMode>true</interactiveMode>
        <offline>false</offline>
      </settings>
    '';

    programs.bash.shellAliases = lib.mkIf config.programs.bash.enable {
      mvn-clean = "mvn clean";
      mvn-compile = "mvn compile";
      mvn-test = "mvn test";
      mvn-package = "mvn package";
      mvn-install = "mvn install";
      mvn-run = "mvn spring-boot:run";
      gradle-build = "gradle build";
      gradle-test = "gradle test";
      gradle-run = "gradle bootRun";
    };
  };
}