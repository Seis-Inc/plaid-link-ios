require 'active_support/core_ext/string/strip'

module Pod
  class Installer
    # Controller class responsible of installing the activated specifications
    # of a single Pod.
    #
    # @note This class needs to consider all the activated specs of a Pod.
    #
    class PodSourceInstaller
      UNENCRYPTED_PROTOCOLS = %w(http git).freeze

      # @return [Sandbox] The installation target.
      #
      attr_reader :sandbox

      # @return [Podfile] the podfile that should be integrated with the user
      #         projects.
      #
      attr_reader :podfile

      # @return [Hash{Symbol=>Array}] The specifications that need to be
      #         installed grouped by platform.
      #
      attr_reader :specs_by_platform

      # @return [Boolean] Whether the installer is allowed to touch the cache.
      #
      attr_reader :can_cache
      alias_method :can_cache?, :can_cache

      # Initialize a new instance
      #
      # @param [Sandbox] sandbox @see #sandbox
      # @param [Podfile] podfile @see #podfile
      # @param [Hash{Symbol=>Array}] specs_by_platform @see #specs_by_platform
      # @param [Boolean] can_cache @see #can_cache
      #
      def initialize(sandbox, podfile, specs_by_platform, can_cache: true)
        @sandbox = sandbox
        @podfile = podfile
        @specs_by_platform = specs_by_platform
        @can_cache = can_cache
      end

      # @return [String] A string suitable for debugging.
      #
      def inspect
        "<#{self.class} sandbox=#{sandbox.root} pod=#{root_spec.name}"
      end

      # @return [String] The name of the pod this installer is installing.
      #
      def name
        root_spec.name
      end

      #-----------------------------------------------------------------------#

      public

      # @!group Installation

      # Creates the target in the Pods project and the relative support files.
      #
      # @return [void]
      #
      def install!
        download_source unless predownloaded? || local?
        PodSourcePreparer.new(root_spec, root).prepare! if local?
        sandbox.remove_local_podspec(name) unless predownloaded? || local? || external?
      end

      # Cleans the installations if appropriate.
      #
      # Cleaning the installation will remove any files that are not used during the build process, based on
      # the podspec and platforms of the target that the pod is integrated into.
      #
      # @see {#clean_installation}
      #
      # @return [void]
      #
      def clean!
        clean_installation unless local?
      end

      # Locks the source files if appropriate.
      #
      # @return [void]
      #
      def lock_files!(file_accessors)
        return if local?
        FileUtils.chmod('u-w', source_files(file_accessors))
      end

      # Unlocks the source files if appropriate.
      #
      # @return [void]
      #
      def unlock_files!(file_accessors)
        return if local?
        FileUtils.chmod('u+w', source_files(file_accessors))
      end

      #-----------------------------------------------------------------------#

      private

      # @!group Installation Steps

      # Downloads the source of the Pod.
      #
      # @return [void]
      #
      def download_source
        verify_source_is_secure(root_spec)
        download_result = Downloader.download(download_request, root, :can_cache => can_cache?)

        if (specific_source = download_result.checkout_options) && specific_source != root_spec.source
          sandbox.store_checkout_source(root_spec.name, specific_source)
        end
      end

      # Verify the source of the spec is secure, which is used to show a warning to the user if that isn't the case
      # This method doesn't verify all protocols, but currently only prohibits unencrypted 'http://' and 'git://''
      # connections.
      #
      # @return [void]
      #
      def verify_source_is_secure(root_spec)
        return if root_spec.source.nil? || (root_spec.source[:http].nil? && root_spec.source[:git].nil?)
        source = if !root_spec.source[:http].nil?
                   URI(root_spec.source[:http].to_s)
                 elsif !root_spec.source[:git].nil?
                   git_source = root_spec.source[:git].to_s
                   return unless git_source =~ /^#{URI.regexp}$/
                   URI(git_source)
                 end
        if UNENCRYPTED_PROTOCOLS.include?(source.scheme) && source.host != 'localhost'
          UI.warn "'#{root_spec.name}' uses the unencrypted '#{source.scheme}' protocol to transfer the Pod. " \
                'Please be sure you\'re in a safe network with only trusted hosts. ' \
                'Otherwise, please reach out to the library author to notify them of this security issue.'
        end
      end

      def download_request
        Downloader::Request.new(
          :spec => root_spec,
          :released => released?,
        )
      end

      #-----------------------------------------------------------------------#

      private

      # Removes all the files not needed for the installation according to the
      # specs by platform.
      #
      # @return [void]
      #
      def clean_installation
        cleaner = Sandbox::PodDirCleaner.new(root, specs_by_platform)
        cleaner.clean!
      end

      # @!group Convenience methods.

      # @return [Array<Specifications>] the specification of the Pod used in
      #         this installation.
      #
      def specs
        specs_by_platform.values.flatten
      end

      # @return [Specification] the root specification of the Pod.
      #
      def root_spec
        specs.first.root
      end

      # @return [Pathname] the folder where the source of the Pod is located.
      #
      def root
        sandbox.pod_dir(root_spec.name)
      end

      # @return [Boolean] whether the source has been pre downloaded in the
      #         resolution process to retrieve its podspec.
      #
      def predownloaded?
        sandbox.predownloaded_pods.include?(root_spec.name)
      end

      # @return [Boolean] whether the pod uses the local option and thus
      #         CocoaPods should not interfere with the files of the user.
      #
      def local?
        sandbox.local?(root_spec.name)
      end

      # @return [Boolean] whether the pod uses an external source (e.g. :podspec) in the
      #         resolution process to retrieve its podspec.
      #
      def external?
        @dependencies ||= podfile.dependencies.select(&:external?).map(&:name)
        @dependencies.include?(root_spec.name)
      end

      def released?
        !local? && !predownloaded? && sandbox.specification(root_spec.name) != root_spec
      end

      # @return [Array<Pathname>] The paths of the source files
      #
      def source_files(file_accessors)
        file_accessors.flat_map(&:source_files)
      end

      #-----------------------------------------------------------------------#
    end
  end
end
