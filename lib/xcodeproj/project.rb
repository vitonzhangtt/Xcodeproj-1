require 'fileutils'
require 'pathname'
require 'xcodeproj/xcodeproj_ext'

require 'xcodeproj/project/hash'
require 'xcodeproj/project/object'

module Xcodeproj

  # This class represents a Xcode project document.
  #
  # It can be used to manipulate existing documents or even create new ones
  # from scratch.
  #
  # An Xcode project document is a plist file where the root is a dictionary
  # containing the following keys:
  #
  # - archiveVersion: the version of the document.
  # - objectVersion: the version of the objects description.
  # - classes: a key that apparently is always empty.
  # - objects: a dictionary where the UUID of every object is associated to
  #   its attributes.
  # - rootObject: the UUID identifier of the root object ({PBXProject}).
  #
  # Every object is in turn a dictionary that specifies an `isa` (the class of
  # the object) and in accordance to it maintains a set attributes. Those
  # attributes might reference one or more other objects by UUID. If the
  # reference is a collection, it is ordered.
  #
  # The {Project} API returns instances of {AbstractObject} which wrap the
  # objects described in the Xcode project document. All the attributes types
  # are preserved from the plist, except for the relationships which are
  # replaced with objects instead of UUIDs.
  #
  # An object might be referenced by multiple objects, an when no other object
  # is references it, it becomes unreachable (the root object is referenced by
  # the project itself). Xcodeproj takes care of adding and removing those
  # objects from the `objects` dictionary so the project is always in a
  # consistent state.
  #
  class Project

    include Object

    # @return [String] the archive version.
    #
    attr_reader :archive_version

    # @return [Hash] an dictionary whose purpose is unknown.
    #
    attr_reader :classes

    # @return [String] the objects version.
    #
    attr_reader :object_version

    # @return [Hash{String => AbstractObject}] A hash containing all the
    #   objects of the project by UUID.
    #
    attr_reader :objects_by_uuid

    # @return [PBXProject] the root object of the project.
    #
    attr_reader :root_object

    # Creates a new Project instance or initializes one with the data of an
    # existing Xcode document.
    #
    # @param [Pathname, String] xcodeproj
    #   The path to the Xcode project document (xcodeproj).
    #
    # @raise If the project versions are more recent than the ones know to
    #   Xcodeproj to prevent it from corrupting existing projects.  Naturally,
    #   this would never happen with a project generated by xcodeproj itself.
    #
    # @raise If it can't find the root object. This means that the project is
    #   malformed.
    #
    # @example Opening a project
    #   Project.new("path/to/Project.xcodeproj")
    #
    def initialize(xcodeproj = nil)
      @objects_by_uuid = {}
      @generated_uuids = []
      @available_uuids = []

      if xcodeproj
        file = File.join(xcodeproj, 'project.pbxproj')
        plist = Xcodeproj.read_plist(file.to_s)

        @archive_version =  plist['archiveVersion']
        @object_version  =  plist['objectVersion']
        @classes         =  plist['classes']

        root_object_uuid = plist['rootObject']
        @root_object = new_from_plist(root_object_uuid, plist['objects'], self)

      if (@archive_version.to_i > Constants::LAST_KNOWN_ARCHIVE_VERSION || @object_version.to_i > Constants::LAST_KNOWN_OBJECT_VERSION)
          raise '[Xcodeproj] Unknown archive or object version.'
        end

        unless @root_object
          raise "[Xcodeproj] Unable to find a root object in #{file}."
        end
      else
        @archive_version =  Constants::LAST_KNOWN_ARCHIVE_VERSION.to_s
        @object_version  =  Constants::LAST_KNOWN_OBJECT_VERSION.to_s
        @classes         =  {}

        root_object = new(PBXProject)
        root_object.main_group = new(PBXGroup)
        root_object.product_ref_group = root_object.main_group.new_group('Products')

        config_list = new(XCConfigurationList)
        config_list.default_configuration_name = 'Release'
        config_list.default_configuration_is_visible = '0'
        root_object.build_configuration_list = config_list

        %w| Release Debug |.each do |name|
          build_configuration = new(XCBuildConfiguration)
          build_configuration.name = name
          build_configuration.build_settings = {}
          config_list.build_configurations << build_configuration
        end

        @root_object = root_object
        root_object.add_referrer(self)
        new_group('Frameworks')
      end
    end

    # Compares the project to another one, or to a plist representation.
    #
    # @param [#to_hash] other the object to compare.
    #
    # @return [Boolean] whether the project is equivalent to the given object.
    #
    def ==(other)
      other.respond_to?(:to_hash) && to_hash == other.to_hash
    end

    def to_s
      "Project with root object UUID: #{root_object.uuid}"
    end

    alias :inspect :to_s



    # @!group Plist serialization

    # Creates a new object from the given UUID and `objects` hash (of a plist).
    #
    # The method sets up any relationship of the new object, generating the
    # destination object(s) if not already present in the project.
    #
    # @note This method is used to generate the root object
    #       from a plist. Subsequent invocation are called by the
    #       {AbstractObject#configure_with_plist}. Clients of {Xcodeproj} are
    #       not expected to call this method.
    #
    # @visibility private.
    #
    # @param [String] uuid
    #   the UUID of the object that needs to be generated.
    #
    # @param [Hash {String => Hash}] objects_by_uuid_plist
    #   the `objects` hash of the plist representation of the project.
    #
    # @param [Boolean] root_object
    #   whether the requested object is the root object and needs to be
    #   retained by the project before configuration to add it to the `objects`
    #   hash and avoid infinite loops.
    #
    # @return [AbstractObject] the new object.
    #
    def new_from_plist(uuid, objects_by_uuid_plist, root_object = false)
      attributes = objects_by_uuid_plist[uuid]
      klass = Object.const_get(attributes['isa'])
      object = klass.new(self, uuid)
      object.add_referrer(self) if root_object

      object.configure_with_plist(objects_by_uuid_plist)
      object
    end

    # @return [Hash] The plist representation of the project.
    #
    def to_plist
      plist = {}
      objects_dictionary = {}
      objects.each { |obj| objects_dictionary[obj.uuid] = obj.to_plist }
      plist['objects']        =  objects_dictionary
      plist['archiveVersion'] =  archive_version.to_s
      plist['objectVersion']  =  object_version.to_s
      plist['classes']        =  classes
      plist['rootObject']     =  root_object.uuid
      plist
    end

    alias :to_hash :to_plist

    # Serializes the internal data as a property list and stores it on disk at
    # the given path (`xcodeproj` file).
    #
    # @example Saving a project
    #   project.save_as("path/to/Project.xcodeproj") #=> true
    #
    # @param [String, Pathname] projpath  The path where the data should be
    #                                     stored.
    #
    # @return [Boolean]                   Whether or not saving was successful.
    #
    def save_as(projpath)
      projpath = projpath.to_s
      FileUtils.mkdir_p(projpath)
      Xcodeproj.write_plist(to_hash, File.join(projpath, 'project.pbxproj'))
    end



    # @!group Creating objects

    # Creates a new object with a suitable UUID.
    #
    # The object is only configured with the default values of the `:simple`
    # attributes, for this reason it is better to use the convenience methods
    # offered by the {AbstractObject} subclasses or by this class.
    #
    # @param [Class] klass     The concrete subclass of AbstractObject for new
    #                          object.
    #
    # @return [AbstractObject] the new object.
    #
    def new(klass)
      object = klass.new(self, generate_uuid)
      object.initialize_defaults
      object
    end

    # Generates a UUID unique for the project.
    #
    # @note UUIDs are not guaranteed to be generated unique because we need to
    #       trim the ones generated in the xcodeproj extension.
    #
    # @note Implementation detail: as objects usually are created serially this
    #       method creates a batch of UUID and stores the not colliding ones,
    #       so the search for collisions with known UUIDS (a performance
    #       bottleneck) is performed is performed less often.
    #
    # @return [String] A UUID unique to the project.
    #
    def generate_uuid
      while @available_uuids.empty?
        generate_available_uuid_list
      end
      @available_uuids.shift
    end

    # @return [Array<String>] the list of all the generated UUIDs.
    #
    #   Used for checking new UUIDs for duplicates with UUIDs already generated
    #   but used for objects which are not yet part of the `objects` hash but
    #   which might be added at a later time.
    #
    attr_reader :generated_uuids

    # Pre-generates the given number of UUIDs. Useful for optimizing
    # performance when the rough number of objects that will be created is
    # known in advance.
    #
    # @param [Integer] count
    #   the number of UUIDs that should be generated.
    #
    # @note This method might generated a minor number of uniques UUIDs than
    #       the given count, because some might be duplicated a thus will be
    #       discarded.
    #
    # @return [void]
    #
    def generate_available_uuid_list(count = 100)
      new_uuids = (0..count).map { Xcodeproj.generate_uuid }
      uniques = (new_uuids - (@generated_uuids + uuids))
      @generated_uuids += uniques
      @available_uuids += uniques
    end

    ## CONVENIENCE METHODS #####################################################

    # @!group Convenience accessors

    # @return [Array<AbstractObject>] all the objects of the project.
    #
    def objects
      objects_by_uuid.values
    end

    # @return [Array<String>] all the UUIDs of the project.
    #
    def uuids
      objects_by_uuid.keys
    end

    # @return [Array<AbstractObject>] all the objects of the project with a
    #   given isa.
    #
    def list_by_class(klass)
      objects.select { |o| o.class == klass }
    end

    # @return [PBXGroup] the main top-level group.
    #
    def main_group
      root_object.main_group
    end

    # @return [ObjectList<PBXGroup>] a list of all the groups in the
    #   project.
    #
    def groups
      main_group.groups
    end

    # Returns a group at the given subpath relative to the main group.
    #
    # @example
    #   frameworks = project['Frameworks']
    #   frameworks.name #=> 'Frameworks'
    #   main_group.children.include? frameworks #=> True
    #
    # @param [String] group_path
    #
    # @return [PBXGroup] the group at the given subpath.
    #
    def [](group_path)
      main_group[group_path]
    end

    # @return [ObjectList<PBXFileReference>] a list of all the files in the
    #   project.
    #
    def files
      objects.select { |obj| obj.class == PBXFileReference }
    end

    # @return [ObjectList<PBXNativeTarget>] A list of all the targets in the
    #   project.
    #
    def targets
      root_object.targets
    end

    # @return [PBXGroup] The group which holds the product file references.
    #
    def products_group
      root_object.product_ref_group
    end

    # @return [ObjectList<PBXFileReference>] A list of the product file
    #   references.
    #
    def products
      products_group.children
    end

    # @return [PBXGroup] the `Frameworks` group creating it if necessary.
    #
    def frameworks_group
      main_group['Frameworks'] || new_group('Frameworks')
    end

    # @return [ObjectList<XCBuildConfiguration>] A list of project wide
    #   build configurations.
    #
    def build_configurations
      root_object.build_configuration_list.build_configurations
    end

    # @param [String] name  The name of a project wide build configuration.
    #
    # @return [Hash]        The build settings of the project wide build
    #                       configuration with the given name.
    #
    def build_settings(name)
      root_object.build_configuration_list.build_settings(name)
    end



    # @!group Convenience methods for generating objects

    # Creates a new file reference at the given subpath of the main group.
    #
    # @param (see PBXGroup#new_file)
    #
    # @return [PBXFileReference] the new file.
    #
    def new_file(path, sub_group_path = nil)
      main_group.new_file(path, sub_group_path)
    end

    # Creates a new group at the given subpath of the main group.
    #
    # @param (see PBXGroup#new_group)
    #
    # @return [PBXGroup] the new group.
    #
    def new_group(name, path = nil)
      main_group.new_group(name, path)
    end

    # Adds a file reference for a system framework to the project.
    #
    # The file reference can then be added to the build files of a
    # {PBXFrameworksBuildPhase}.
    #
    # @example
    #
    #     framework = project.add_system_framework('QuartzCore')
    #
    #     target = project.targets.first
    #     build_phase = target.frameworks_build_phases.first
    #     build_phase.files << framework.buildFiles.new
    #
    # @param [String] name        The name of a framework in the SDK System
    #                             directory.
    # @return [PBXFileReference]  The file reference object.
    #
    def add_system_framework(name)
      path = "System/Library/Frameworks/#{name}.framework"
      if file = frameworks_group.files.first { |f| f.path == path }
        file
      else
        framework_ref = frameworks_group.new_file(path)
        framework_ref.name = "#{name}.framework"
        framework_ref.source_tree = 'SDKROOT'
        framework_ref
      end
    end

    # @return [PBXNativeTarget] Creates a new target and adds it to the
    #   project.
    #
    #   The target is configured for the given platform and its file reference
    #   it is added to the {products_group}.
    #
    #   The target is pre-populated with common build phases, and all the
    #   Frameworks of the project are added to to its Frameworks phase.
    #
    # @todo Adding all the Frameworks is required by CocoaPods and should be
    #       performed there.
    #
    # @param [Symbol] type
    #   the type of target.
    #   Can be `:application`, `:dynamic_library` or `:static_library`.
    #
    # @param [String] name
    #   the name of the static library product.
    #
    # @param [Symbol] platform
    #   the platform of the static library.
    #   Can be `:ios` or `:osx`.
    #
    def new_target(type, name, platform)
      add_system_framework(platform == :ios ? 'Foundation' : 'Cocoa')

      # Target
      target = new(PBXNativeTarget)
      targets << target
      target.name = name
      target.product_name = name
      target.product_type = Constants::PRODUCT_TYPE_UTI[type]
      target.build_configuration_list = configuration_list(platform)

      # Product
      product = products_group.new_static_library(name)
      target.product_reference = product

      # Build phases
      target.build_phases << new(PBXCopyFilesBuildPhase)
      frameworks_phase = new(PBXFrameworksBuildPhase)
      frameworks_group.files.each { |framework| frameworks_phase.add_file_reference(framework) }
      target.build_phases << frameworks_phase
      target.build_phases << new(PBXShellScriptBuildPhase)

      target
    end

    # Returns a new configuration list, populated with release and debug
    # configurations with common build settings for the given platform.
    #
    # @param [Symbol] platform
    #   the platform for the configuration list, can be `:ios` or `:osx`.
    #
    # @return [XCConfigurationList] the generated configuration list.
    #
    def configuration_list(platform)
      cl = new(XCConfigurationList)
      cl.default_configuration_is_visible = '0'
      cl.default_configuration_name = 'Release'

      release_conf = new(XCBuildConfiguration)
      release_conf.name = 'Release'
      release_conf.build_settings = configuration_list_settings(platform, :release)

      debug_conf = new(XCBuildConfiguration)
      debug_conf.name = 'Debug'
      debug_conf.build_settings = configuration_list_settings(platform, :debug)

      cl.build_configurations << release_conf
      cl.build_configurations << debug_conf
      cl
    end

    # Returns the common build settings for a given platform and configuration
    # name.
    #
    # @param [Symbol] platform
    #   the platform for the build settings, can be `:ios` or `:osx`.
    #
    # @param [Symbol] name
    #   the name of the build configuration, can be `:release` or `:debug`.
    #
    # @return [Hash] The common build settings
    #
    def configuration_list_settings(platform, name)
      common_settings = Constants::COMMON_BUILD_SETTINGS
      bs = common_settings[:all].dup
      bs = bs.merge(common_settings[name])
      bs = bs.merge(common_settings[platform])
      bs = bs.merge(common_settings[[platform, name]])
      bs
    end

  end
end
