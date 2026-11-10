// SPDX-License-Identifier: GPL-2.0-or-later
// Use the bundled DjVuLibre to replace page components without rebuilding
// the directory IDs or re-encoding the untouched pages.
#include "config.h"
#include "ByteStream.h"
#include "DataPool.h"
#include "DjVmDoc.h"
#include "DjVmNav.h"
#include "GException.h"
#include "GURL.h"
#include "IFFByteStream.h"
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>
#ifdef HAVE_NAMESPACES
using namespace DJVU;
#endif

int main(int argc, char **argv) {
    if (argc != 4) return 2;
    G_TRY {
        const GURL::Filename::UTF8 source(argv[1]);
        const GP<DataPool> input(DataPool::create(source));
        const GP<DjVmDoc> book(DjVmDoc::create());
        book->read(input);

        // DjVmDoc loads the directory and components; carry over the NAVM chunk separately.
        const GP<IFFByteStream> iff(IFFByteStream::create(input->get_stream()));
        GUTF8String id;
        iff->get_chunk(id);
        if (id != "FORM:DJVM") G_THROW("Expected a bundled DjVu document");
        while (iff->get_chunk(id)) {
            if (id == "NAVM") {
                const GP<DjVmNav> nav(DjVmNav::create());
                nav->decode(iff->get_bytestream());
                book->set_djvm_nav(nav);
                break;
            }
            if (id.substr(0, 5) == "FORM:") break;
            iff->close_chunk();
        }

        const GP<DjVmDir> directory(book->get_djvm_dir());
        const int files = directory->get_files_num();
        std::vector<GUTF8String> thumbnails;
        long long payloadSize = 0;
        for (int position = 0; position < files; ++position) {
            const GP<DjVmDir::File> file(directory->pos_to_file(position));
            if (!file) G_THROW("Invalid bundled directory record");
            if (file->is_thumbnails()) {
                thumbnails.push_back(file->get_load_name());
                continue;
            }
            payloadSize += file->size;
            if (!file->is_page()) continue;
            const std::string path = std::string(argv[2]) + "/page-" +
                std::to_string(file->get_page_num() + 1) + ".djvu";
            if (!std::ifstream(path.c_str()).good()) continue;
            const GP<DataPool> replacement(DataPool::create(GURL::Filename::UTF8(path.c_str())));
            const int length = replacement->get_length();
            if (length <= 4 || length > 0xffffff) G_THROW("Adjusted page exceeds the DjVu directory entry limit");
            payloadSize += length - 4 - file->size;
            // Capture the directory record before deleting it. Keep filenames and titles
            // because bookmarks and hyperlinks may refer to page IDs rather than numbers.
            const GUTF8String name = file->get_save_name();
            const GUTF8String loadName = file->get_load_name();
            const GUTF8String title = file->get_title();
            book->delete_file(loadName);
            book->insert_file(replacement, DjVmDir::File::PAGE, loadName, name, title, position);
        }
        if (payloadSize > 2000000000LL) G_THROW("Adjusted DjVu is too large");
        for (const auto &thumbnail : thumbnails) book->delete_file(thumbnail);
        book->write(ByteStream::create(GURL::Filename::UTF8(argv[3]), "wb"));
        return 0;
    } G_CATCH(error) {
        std::fprintf(stderr, "%s\n", error.get_cause());
        return 1;
    } G_ENDCATCH;
    return 1;
}
