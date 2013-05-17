require 'rubygems'
require 'vagrant'


module Vagrant
  module BaseBuilder
    def prebuild(build, listener)
    end

    def perform(build, launcher, listener)
      # This should be set by the VagrantWrapper
      @vagrant = build.env[:vagrant]
      @provider = build.env[:vagrant_provider]

      if @vagrant.nil?
        build.halt "OH CRAP! I don't seem to have a Vagrant instance!"
      end

      if multivms?
          perform_multi_vm(build, launcher, listener)
      else
          perform_single_vm(build, launcher, listener)
      end
    end

    def multivms?
      @vagrant.machine_names.length > 1
    end

    def vms
      @vagrant.machine_names.map do |machine_name|
        @vagrant.machine(machine_name, @provider)
      end
    end

    def vm
      @vagrant.machine(@vagrant.primary_machine_name, @provider)
    end

    def perform_single_vm(build, launcher, listener)
        unless vm.state.id == :running
            build.halt "Vagrant VM doesn't appear to be running! State is #{vm.state.id}"
        end

        listener.info("Running the command in Vagrant with \"#{vagrant_method.to_s}\":")
        @command.split("\n").each do |line|
            listener.info("+ #{line}")
        end

        code = vm.communicate.send(vagrant_method, @command) do |type, data|
        # type is one of [:stdout, :stderr, :exit_status]
        # data is a string for stdout/stderr and an int for exit status
            if type == :stdout
                listener.info data
            elsif type == :stderr
                listener.error data
            end
        end
        unless code == 0
            build.halt 'Command failed!'
        end
    end

    def perform_multi_vm(build, launcher, listener)
        vms.each do |vm|
            unless vm.state.id == :running
                build.halt "Vagrant VM #{vm.name} doesn't appear to be running!"
            end

            listener.info("Running the command in Vagrant on VM #{vm.name} with \"#{vagrant_method.to_s}\":")
            @command.split("\n").each do |line|
                listener.info("+ #{line}")
            end

            code = vm.communicate.send(vagrant_method, @command) do |type, data|
            # type is one of [:stdout, :stderr, :exit_status]
            # data is a string for stdout/stderr and an int for exit status
                if type == :stdout
                    listener.info data
                elsif type == :stderr
                    listener.error data
                end
            end
            unless code == 0
                build.halt 'Command failed!'
            end
        end
    end
  end

  class UserBuilder < Jenkins::Tasks::Builder
    display_name "Execute shell script in Vagrant"

    include BaseBuilder

    attr_accessor :command

    def initialize(attrs)
      @command = attrs["command"]
    end

    def vagrant_method
      :execute
    end
  end

  class SudoBuilder < Jenkins::Tasks::Builder
    display_name "Execute shell script in Vagrant as admin"

    include BaseBuilder

    attr_accessor :command

    def initialize(attrs)
      @command = attrs["command"]
    end

    def vagrant_method
      :sudo
    end
  end

  class ProvisionBuilder < Jenkins::Tasks::Builder
    display_name 'Provision the Vagrant VM(s)'

    include BaseBuilder

    def initialize(attrs)
    end

    def prebuild(build, listener)
    end

    def perform(build, launcher, listener)
      @vagrant = build.env[:vagrant]
      if @vagrant.nil?
        build.halt "OH CRAP! I don't seem to have a Vagrant instance"
      end

      if multivms?
          vms.each do |vm|
              unless vm.state.id == :running
                  build.halt "Vagrant VM #{vm.name} doesn't appear to be running!"
              end
              listener.info("Provisioning the Vagrant VM #{vm.name}.. (this may take a while)")
              @vagrant.cli('provision', "#{vm.name}")
          end
      else
        unless vm.state.id == :running
            build.halt "Vagrant VM doesn't appear to be running!"
        end
        listener.info("Provisioning the Vagrant VM.. (this may take a while)")
        @vagrant.cli('provision')
      end
    end
  end
end
