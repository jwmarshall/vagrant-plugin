require 'rubygems'
require 'vagrant'
require 'lockfile'
require 'tmpdir'

module Vagrant
  # This will handle proxying output from Vagrant into Jenkins
  class ConsoleInterface
    attr_accessor :listener, :resource

    def initializer(resource)
      @listener = nil
      @resource = resource
    end

    [:ask, :warn, :error, :info, :success].each do |method|
      define_method(method) do |message, *opts|
        @listener.info(message)
      end
    end

    [:clear_line, :report_progress].each do |method|
      # By default do nothing, these aren't logged
      define_method(method) do |*args|
      end
    end

    def ask(*args)
      super

      # Silent can't do this, obviously.
      raise Vagrant::Errors::UIExpectsTTY
    end

    def scope(scope_name)
      self
    end
  end

  class BasicWrapper < Jenkins::Tasks::BuildWrapper
    display_name "Boot Vagrant box"

    attr_accessor :vagrantfile, :provider
    def initialize(attrs)
      @vagrant = nil
      @vagrantfile = attrs['vagrantfile']
      @provider = fix_provider(attrs['provider']) || :virtualbox
    end

    def fix_provider(s)
      s == "" ? nil : s.to_sym
    end

    def path_to_vagrantfile(build)
      if @vagrantfile.nil?
        return build.workspace.to_s
      end

      return File.expand_path(File.join(build.workspace.to_s, @vagrantfile))
    end

    # Called some time before the build is to start.
    def setup(build, launcher, listener)
      path = path_to_vagrantfile(build)

      unless File.exists? File.join(path, 'Vagrantfile')
        listener.info("There is no Vagrantfile in your workspace!")
        listener.info("We looked in: #{path}")
        build.native.setResult(Java.hudson.model.Result::NOT_BUILT)
        build.halt
      end

      listener.info("Running Vagrant with version: #{Vagrant::VERSION}")
      @vagrant = Vagrant::Environment.new(:cwd => path, :ui_class => ConsoleInterface)
      @vagrant.ui.listener = listener

      listener.info("Vagrant in: #{path}")
      listener.info("Vagrant provider: #{@provider}")

      listener.info "Vagrantfile loaded, bringing Vagrant box up for the build"
      # Vagrant doesn't currently implement any locking, neither does
      # VBoxManage, and it will fail if importing two boxes concurrently, so use
      # a file lock to make sure that doesn't happen.
      Lockfile.new(File.join(Dir.tmpdir, ".vagrant-jenkins-plugin.lock")) do
        begin
          @vagrant.cli('up')
        # Since we're now provisioning on an up, catch exception if provision fails. Vagrant
        # leaves the box running even if provision fails which is bad, as another box gets 
        # created next time Jenkins runs the project. If provisioning is broke you will end 
        # up with a lot of virtualboxes running. So lets catch the exception and halt the build
        # destroying the box on halt.
        rescue => exception
          listener.info("#{exception.backtrace}")
          listener.info "**********Something went wrong! Destroying the Vagrant box************"
          @vagrant.cli('destroy', '-f')
          build.halt "ERROR: #{exception.message}"
        end
      end
      listener.info "Vagrant box is online, continuing with the build"

      build.env[:vagrant] = @vagrant
      build.env[:vagrant_provider] = @provider
      # We use this variable to determine if we have changes worth packaging,
      # i.e. if we have actually done anything with the box, we will mark it
      # dirty and can then take further action based on that
      build.env[:vagrant_dirty] = false
    end

    # Called some time when the build is finished.
    def teardown(build, listener)
      if @vagrant.nil?
        return
      end

      unless build.env[:vagrant_disable_destroy]
        listener.info "Build finished, destroying the Vagrant box"
        @vagrant.cli('destroy', '-f')
      end
    end
  end
end
