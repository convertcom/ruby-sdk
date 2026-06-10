# frozen_string_literal: true

# Deep-freeze assertion helpers for installed config snapshots.
#
# Story 2.5 installs config as a recursively frozen, string-keyed snapshot so
# decision paths can read it lock-free without torn reads. The deep-freeze
# contract is asserted by walking every node of the structure and checking
# +#frozen?+ — this helper centralises that walk so Story 2.7's refresh-install
# specs reuse it rather than re-implementing the recursion.
module DeepFrozen
  module_function

  # Walk +node+ and collect every contained Hash / Array / String node that is
  # NOT frozen. An empty result proves the whole structure is deep-frozen.
  #
  # Symbols, Integers, Floats, true/false/nil are immutable (or always frozen)
  # in every supported Ruby, so they are not inspected — only the mutable
  # container/string nodes that {DataManager#install_config} must freeze.
  #
  # @param node [Object] the structure to inspect (typically the installed snapshot).
  # @return [Array<Object>] the unfrozen mutable nodes found (empty when fully frozen).
  def unfrozen_nodes(node)
    found = [] #: Array[untyped]
    walk(node, found)
    found
  end

  # @param node [Object] structure to inspect.
  # @return [Boolean] true iff every Hash/Array/String node is frozen.
  def deep_frozen?(node)
    unfrozen_nodes(node).empty?
  end

  # Recursive walk: record a mutable node if it is unfrozen, then descend into
  # its children (hashes and arrays only; strings and scalars are leaves).
  def walk(node, found)
    return unless node.is_a?(Hash) || node.is_a?(Array) || node.is_a?(String)

    found << node unless node.frozen?
    descend(node, found)
  end

  # Descend into a container node's children. Leaves (String/scalar) have none.
  def descend(node, found)
    if node.is_a?(Hash)
      node.each do |key, value|
        walk(key, found)
        walk(value, found)
      end
    elsif node.is_a?(Array)
      node.each { |element| walk(element, found) }
    end
  end
end
