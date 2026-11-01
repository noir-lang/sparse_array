use crate::{insert_sorted_keys_and_values, MutSparseArray, MutSparseArrayBase, U32RangeTraits};

trait RangeTraits {
    fn less_than(lhs: Field, rhs: Field) -> bool;
    fn assert_sorted(lhs: Field, rhs: Field);
    fn assert_greater_than_zero(val: Field);
    fn assert_greater_than_or_equal(lhs: Field, rhs: Field);
}

impl RangeTraits for U32RangeTraits {
    fn less_than(lhs: Field, rhs: Field) -> bool {
        lhs as u32 < rhs as u32
    }

    fn assert_sorted(lhs: Field, rhs: Field) {
        let result = (rhs - lhs - 1);
        result.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_zero(val: Field) {
        val.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_or_equal(lhs: Field, rhs: Field) {
        (lhs - rhs).assert_max_bit_size::<32>();
    }
}

struct FieldComparisonFuncs {}

impl RangeTraits for FieldComparisonFuncs {
    fn less_than(lhs: Field, rhs: Field) -> bool {
        lhs.lt(rhs)
    }

    fn assert_sorted(lhs: Field, rhs: Field) {
        let result = (rhs - lhs - 1);
        result.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_zero(val: Field) {
        val.assert_max_bit_size::<32>();
    }

    fn assert_greater_than_or_equal(lhs: Field, rhs: Field) {
        (lhs - rhs).assert_max_bit_size::<32>();
    }
}

impl<let N: u32, T, ComparisonFuncs> MutSparseArrayBase<N, T, ComparisonFuncs>
where
    T: std::default::Default,
    ComparisonFuncs: RangeTraits,
{

    pub(crate) fn create<let M: u32>(_keys: [u32; M], _values: [T; M], size: u32) -> Self {
        assert(M <= N);
        assert(size >= 1);
        let _maximum: u32 = size - 1;
        let mut r: Self = MutSparseArrayBase {
            keys: [0; N + 2],
            values: [T::default(); N + 3],
            linked_keys: [0; N + 2],
            maximum: _maximum,
            maximum_index: M + 1,
            tail_ptr: 0,
        };

        insert_sorted_keys_and_values(_keys, _values, _maximum, &mut r.keys, &mut r.values);

        for i in 0..M + 2 {
            r.linked_keys[i] = i + 1;
        }
        // set the last linked key to 2^32 - 1
        r.linked_keys[M + 1] = 0xFFFFFFFF;

        r.tail_ptr = M + 2;
        r
    }

    unconstrained fn search_for_key(self, target: u32) -> (bool, u32) {
        let mut found = false;
        let mut found_index = 0;
        let mut previous_less_than_or_equal_to_target = false;
        let mut iterator = 0; // first entry is always smallest
        let mut prev = 0;
        for _ in 0..self.tail_ptr as u32 {
            let current_less_than_or_equal_to_target = self.keys[iterator] as u64 <= target as u64;
            if (self.keys[iterator] == target) {
                found = true;
                found_index = iterator;
                break;
            }
            if (previous_less_than_or_equal_to_target & !current_less_than_or_equal_to_target) {
                found_index = prev;
                break;
            }
            previous_less_than_or_equal_to_target = current_less_than_or_equal_to_target;
            prev = iterator;
            iterator = self.linked_keys[iterator] as u32;
            //    }
        }

        // 0 and `maximum` can be stored in more than one slot, so always return the sentinel
        if target == 0 {
            found_index = 0;
        } else if target == self.maximum {
            found_index = self.maximum_index;
        }
        (found, found_index)
    }

    unconstrained fn __check_if_can_insert(self, found: bool) {
        assert(
            (found == true) | (self.tail_ptr < N + 2),
            "MutSparseArray::set exceeded maximum size of array",
        );
    }

    /**
     * @brief check the result of `search_for_key(idx)`
     * @details if `found`, `self.keys[found_index] == idx`, and 0 and `maximum` must use their
     *          sentinel slots: unused slots also hold key 0, and either may also be an input key,
     *          so other slots can hold stale values.
     *          if `!found`, `self.keys[found_index] < idx < self.keys[self.linked_keys[found_index]]`
     **/
    fn assert_valid_lookup(self, idx: u32, found: bool, found_index: u32) {
        if found {
            assert(self.keys[found_index] == idx);
            if idx == 0 {
                assert(found_index == 0);
            } else if idx == self.maximum {
                assert(found_index == self.maximum_index);
            }
        } else {
            assert(self.keys[found_index] < idx);
            assert(idx < self.keys[self.linked_keys[found_index]]);
        }
    }

    fn set(&mut self, idx: u32, value: T) {
        // Safety: the result is checked by `assert_valid_lookup`
        let (found, found_index) = unsafe { self.search_for_key(idx) };

        // check can be unsafe because, if check fails, unsatisfiable constraints are created
        // due to an array overflow when accesing `self.linked_keys[self.tail_ptr]`
        unsafe { self.__check_if_can_insert(found) };

        self.assert_valid_lookup(idx, found, found_index);
        let rhs_index = self.linked_keys[found_index];

        // lhs points to tail_ptr
        // tail_ptr points to rhs
        if (found == false) {
            self.keys[self.tail_ptr] = idx;

            self.linked_keys[found_index] = self.tail_ptr;

            self.linked_keys[self.tail_ptr] = rhs_index;
            self.values[self.tail_ptr + 1] = value;
            self.tail_ptr += 1;
        } else {
            self.values[found_index + 1] = value;
        }
    }

    fn get(self, idx: u32) -> T {
        // Safety: the result is checked by `assert_valid_lookup`
        let (found, found_index) = unsafe { self.search_for_key(idx) };

        self.assert_valid_lookup(idx, found, found_index);
        let value_index = (found_index + 1) * found as u32;
        self.values[value_index]
    }
}

impl<let N: u32, T> MutSparseArray<N, T>
where
    T: std::default::Default,
{
    pub fn create<let M: u32>(keys: [u32; M], values: [T; M], size: u32) -> Self {
        Self { inner: MutSparseArrayBase::create(keys, values, size) }
    }

    pub fn get(self, idx: u32) -> T {
        self.inner.get(idx)
    }

    pub fn set(&mut self, idx: u32, value: T) {
        self.inner.set(idx, value);
    }

    fn length(self) -> u32 {
        self.inner.maximum + 1
    }
}
mod test {

    use crate::MutSparseArray;
    #[test]
    fn test_sparse_lookup() {
        let mut example: MutSparseArray<5, Field> =
            MutSparseArray::create([1, 99, 7, 5], [123, 101112, 789, 456], 100);

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        example.set(55, 222);
        assert(example.get(55) == 222);
        example.set(55, 333);
        assert(example.get(55) == 333);
        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 55) & (i != 99)) {
                assert(example.get(i) == 0);
            }
        }
    }
    #[test]
    fn test_sparse_lookup_boundary_cases() {
        // what about when keys[0] = 0 and keys[N-1] = 2^32 - 1?
        let example: MutSparseArray<6, _> = MutSparseArray::create(
            [0, 99999, 7, 0xfffffffe],
            [123, 101112, 789, 456],
            0xFFFFFFFF,
        );

        assert(example.get(0) == 123);
        assert(example.get(99999) == 101112);
        assert(example.get(7) == 789);
        assert(example.get(0xfffffffe) == 456);
        assert(example.get(0xfffffffd) == 0);
    }

    #[test]
    fn test_overwrite_in_a_full_array_succeeds() {
        let mut example: MutSparseArray<4, _> =
            MutSparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);
        assert(example.get(5) == 456);
        example.set(5, 444);
        assert(example.get(5) == 444);
    }

    #[test(should_fail_with = "MutSparseArray::set exceeded maximum size of array")]
    fn test_insert_beyond_maximum_fails() {
        let mut example: MutSparseArray<4, _> =
            MutSparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);
        example.set(11, 444);
        assert(example.get(100000) == 0);
    }

    #[test]
    fn test_overwrite_boundary_keys() {
        let mut example: MutSparseArray<5, Field> =
            MutSparseArray::create([5, 9, 0], [50, 90, 10], 10);
        example.set(0, 11);
        example.set(9, 99);
        example.set(4, 44);

        assert(example.get(0) == 11);
        assert(example.get(9) == 99);
        assert(example.get(4) == 44);
        assert(example.get(3) == 0);
    }

    #[test]
    fn test_maximum_not_in_input() {
        let mut example: MutSparseArray<1, Field> = MutSparseArray::create([5], [50], 10);
        assert(example.get(9) == 0);
        example.set(9, 99);
        assert(example.get(9) == 99);
    }

    #[test(should_fail)]
    fn test_lookup_rejects_absent_key_marked_found() {
        let example: MutSparseArray<2, Field> = MutSparseArray::create([2, 8], [20, 80], 10);
        // keys[1] = 2, and 2 <= 3 <= keys[linked_keys[1]] = 8
        example.inner.assert_valid_lookup(3, true, 1);
    }

    #[test(should_fail)]
    fn test_lookup_rejects_stale_zero_slot() {
        let mut example: MutSparseArray<2, Field> = MutSparseArray::create([0, 8], [10, 80], 10);
        example.set(0, 11);
        // keys[1] = 0 still maps to the old value 10
        example.inner.assert_valid_lookup(0, true, 1);
    }

    #[test(should_fail)]
    fn test_lookup_rejects_unused_slot() {
        let example: MutSparseArray<4, Field> = MutSparseArray::create([0, 2], [10, 20], 10);
        // keys[5] is unused, so holds key 0 and maps to the default value
        example.inner.assert_valid_lookup(0, true, 5);
    }

    #[test(should_fail)]
    fn test_lookup_rejects_stale_maximum_slot() {
        let mut example: MutSparseArray<2, Field> = MutSparseArray::create([2, 9], [20, 90], 10);
        example.set(9, 99);
        // keys[2] = 9 is the input copy of the end sentinel, and still maps to 90
        example.inner.assert_valid_lookup(9, true, 2);
    }

    #[test(should_fail)]
    fn test_sparse_lookup_overflow() {
        let example: MutSparseArray<8, _> =
            MutSparseArray::create([1, 5, 7, 99999], [123, 456, 789, 101112], 100000);

        assert(example.get(100000) == 0);
    }

    #[test(should_fail)]
    fn test_sparse_lookup_boundary_case_overflow() {
        let example: MutSparseArray<4, _> =
            MutSparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0xFFFFFFFF);

        assert(example.get(0xFFFFFFFF) == 0);
    }

    #[test(should_fail)]
    fn test_sparse_lookup_key_exceeds_maximum() {
        let example: MutSparseArray<6, _> =
            MutSparseArray::create([0, 5, 7, 0xffffffff], [123, 456, 789, 101112], 0xffffffff);
        assert(example.length() == 0xffffffff);
    }

    // Regression test for https://github.com/noir-lang/noir-library-claude/issues/6
    // The keys [3, 1, 2] sort via a 3-cycle permutation, so `sort_indices` differs
    // from its inverse. `create` must use the inverse map when populating values,
    // otherwise `get(key)` returns a different key's value.
    #[test]
    fn test_sparse_lookup_non_involution_key_order() {
        let example: MutSparseArray<4, Field> =
            MutSparseArray::create([3, 1, 2], [30, 10, 20], 100);

        assert(example.get(1) == 10);
        assert(example.get(2) == 20);
        assert(example.get(3) == 30);
    }

    #[test]
    fn test_sparse_lookup_u32() {
        let example: MutSparseArray<8, _> = MutSparseArray::create(
            [1, 99, 7, 5],
            [123 as u32, 101112 as u32, 789 as u32, 456 as u32],
            100,
        );

        assert(example.get(1) == 123);
        assert(example.get(5) == 456);
        assert(example.get(7) == 789);
        assert(example.get(99) == 101112);

        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i) == 0);
            }
        }
    }

    struct F {
        foo: [Field; 3],
    }
    impl std::cmp::Eq for F {
        fn eq(self, other: Self) -> bool {
            self.foo == other.foo
        }
    }

    impl std::default::Default for F {
        fn default() -> Self {
            F { foo: [0; 3] }
        }
    }

    #[test]
    fn test_sparse_lookup_struct() {
        let values = [
            F { foo: [1, 2, 3] },
            F { foo: [4, 5, 6] },
            F { foo: [7, 8, 9] },
            F { foo: [10, 11, 12] },
        ];
        let example: MutSparseArray<5, _> = MutSparseArray::create([1, 99, 7, 5], values, 100000);

        assert(example.get(1) == values[0]);
        assert(example.get(5) == values[3]);
        assert(example.get(7) == values[2]);
        assert(example.get(99) == values[1]);
        for i in 0..100 {
            if ((i != 1) & (i != 5) & (i != 7) & (i != 99)) {
                assert(example.get(i) == F::default());
            }
        }
    }
}
