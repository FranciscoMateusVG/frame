defmodule Frame.Unit.CatDomainTest do
  use ExUnit.Case, async: true

  alias Frame.Domain.Cat

  describe "parse_cat_name/1 (CatNameSchema)" do
    test "should accept a valid name" do
      assert {:ok, _} = Cat.parse_cat_name("Whiskers")
    end

    test "should reject an empty string" do
      assert {:error, _} = Cat.parse_cat_name("")
    end

    test "should reject a name over 100 characters" do
      assert {:error, _} = Cat.parse_cat_name(String.duplicate("a", 101))
    end

    test "should accept a name at exactly 100 characters" do
      assert {:ok, _} = Cat.parse_cat_name(String.duplicate("a", 100))
    end

    test "should trim whitespace" do
      assert {:ok, "Luna"} = Cat.parse_cat_name("  Luna  ")
    end

    test "should accept single-character name" do
      assert {:ok, _} = Cat.parse_cat_name("X")
    end

    test "should reject whitespace-only string (trims to empty)" do
      assert {:error, _} = Cat.parse_cat_name("   ")
    end
  end

  describe "parse_cat_id/1 (CatIdSchema)" do
    test "should accept a valid UUID v4" do
      assert {:ok, _} = Cat.parse_cat_id("550e8400-e29b-41d4-a716-446655440000")
    end

    test "should reject an invalid string" do
      assert {:error, _} = Cat.parse_cat_id("not-a-uuid")
    end

    test "should reject an empty string" do
      assert {:error, _} = Cat.parse_cat_id("")
    end
  end

  describe "parse_create_cat_input/1 (CreateCatInputSchema)" do
    test "should accept valid input" do
      assert {:ok, _} =
               Cat.parse_create_cat_input(%{
                 id: "550e8400-e29b-41d4-a716-446655440000",
                 name: "Whiskers"
               })
    end

    test "should reject missing name" do
      assert {:error, _} =
               Cat.parse_create_cat_input(%{id: "550e8400-e29b-41d4-a716-446655440000"})
    end

    test "should reject missing id" do
      assert {:error, _} = Cat.parse_create_cat_input(%{name: "Whiskers"})
    end
  end
end
